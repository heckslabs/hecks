    /// Evaluate one with-spec entry into a runtime Value at PM
    /// dispatch time. Four kinds :
    ///
    ///   - `Literal { value }`             → `Value::Str(value)`
    ///   - `FromEvent { name, default }`    → `event.data[name]` ;
    ///                                        falls back to literal
    ///                                        from `default` ;
    ///                                        returns `None` when
    ///                                        both are absent.
    ///   - `FromPm { name, default }`       → `pm.attributes[name]` ;
    ///                                        same fallback semantics.
    ///   - `FromIter { field }`             → i221-B : reads
    ///                                        `iter_data[field]` (the
    ///                                        current sweep record).
    ///                                        Returns `None` outside a
    ///                                        `for_each:` sweep.
    ///
    /// Returns `None` when no value resolves (caller skips the key
    /// so the receiving aggregate sees no entry — same as if the
    /// dispatch never named it).
    ///
    /// Phase 2.c — FromPm now reads from the PM instance's
    /// `attributes` hash (populated by handlers' `set` directives).
    /// When the attribute is absent the spec's `default` fires ;
    /// when both are absent, returns None.
    ///
    /// i221-B — `iter_data` carries the current sweep record's fields
    /// (set by `drain_policies` when a DispatchSpec has `for_each:
    /// Some(_)`). `None` for bare dispatches ; `Some(&fields)` per
    /// record during a sweep loop.
    fn evaluate_value_spec(
        &self,
        spec: &crate::ir::ValueSpec,
        event: &Event,
        pm_name: &str,
        correlation_id: &str,
        iter_data: Option<&HashMap<String, Value>>,
    ) -> Option<Value> {
        use crate::ir::ValueSpec;
        match spec {
            ValueSpec::Literal { value } => Some(Value::Str(value.clone())),
            ValueSpec::FromEvent { name, default } => {
                if let Some(v) = event.data.get(name) {
                    return Some(v.clone());
                }
                default.as_ref().map(|d| Value::Str(d.clone()))
            }
            ValueSpec::FromPm { name, default } => {
                if let Some(v) = self.pm_engine.read_attribute(pm_name, correlation_id, name) {
                    return Some(Value::Str(v.to_string()));
                }
                default.as_ref().map(|d| Value::Str(d.clone()))
            }
            // i221-B — pull the named field off the current sweep
            // record. When `iter_data` is `None` (bare dispatch), or
            // the record doesn't carry the field, returns `None` and
            // the caller leaves the key unset.
            ValueSpec::FromIter { field } => {
                iter_data.and_then(|m| m.get(field).cloned())
            }
        }
    }

    /// Phase 2.c — resolve every `set` directive on the firing
    /// handler into concrete (attr, String) pairs, ready to write to
    /// the PM instance. Reuses the same ValueSpec evaluator as the
    /// dispatch with-spec ; coerces the resolved Value to its
    /// Display form (matches the storage convention — attributes
    /// round-trip as JSON strings). Skips entries that resolve to
    /// None (no event match + no default = leave attr untouched).
    fn pm_set_pairs(&self, t: &PMTrigger, event: &Event) -> Vec<(String, String)> {
        // The set_specs live on the handler that fired ; PMTrigger
        // doesn't carry them directly (the engine drops them when it
        // returns), so re-look them up via pm_name + (event_name,
        // from_state). One handler matches per (event_type, from_state)
        // pair (Ruby builder enforces this via single-entry
        // transition).
        let binding = match self.pm_engine.bindings().find(|b| b.name == t.pm_name) {
            Some(b) => b,
            None => return Vec::new(),
        };
        let handler = match binding
            .handlers
            .iter()
            .find(|h| h.event_type == t.event_name && h.from_state == t.from_state)
        {
            Some(h) => h,
            None => return Vec::new(),
        };
        let mut out = Vec::new();
        for (attr, spec) in &handler.set_specs {
            // i221-B — set_specs run BEFORE the dispatch loop ; they
            // can't be inside a `for_each:` iteration (the iter
            // context belongs to the dispatched command, not the PM
            // attribute write). Pass `None` for iter_data so any
            // stray `from_iter(:_)` in a set spec resolves to None
            // (= no write), which is the correct fallback semantics.
            if let Some(v) = self.evaluate_value_spec(spec, event, &t.pm_name, &t.correlation_id, None) {
                out.push((attr.clone(), v.to_string()));
            }
        }
        out
    }

    /// i221-B — resolve a `for_each: { from: "Aggregate.query" }`
    /// sweep source to a list of per-record field maps. Each returned
    /// HashMap carries the record's fields keyed by attribute name ;
    /// `from_iter(:field)` in the dispatch's with-spec reads from
    /// these maps during the cascade loop.
    ///
    /// Resolution order :
    ///
    ///   1. Look up the named query in the source aggregate's IR ;
    ///      run it through `resolve_query` to apply declared wheres /
    ///      order_by / limit. Returns the structured records.
    ///   2. When the query name doesn't match a declared query (the
    ///      Synapse.cold / Signal.cold use case where the predicate
    ///      lives in the aggregate's specifications block, not its
    ///      queries), fall back to `repo.all()` so the sweep at
    ///      least enumerates every record. Future i225 work : lift
    ///      specifications into queryable predicates so the sweep is
    ///      a true filtered enumeration.
    ///
    /// An empty sweep returns an empty Vec, which the caller treats
    /// as "no records → no dispatches" — same as a `for_each` over an
    /// empty iterable.
    fn sweep_records(&self, spec: &crate::ir::ForEachSpec) -> Vec<HashMap<String, Value>> {
        // First : try the structured query path. Filter by aggregate
        // name AND (when supplied) bluebook context — disambiguates
        // when the same aggregate name exists in multiple bluebooks
        // (e.g. mind/state/musing.bluebook + mind/musings/musings.bluebook
        // both declare "Musing").
        let has_query = self.domain.aggregates.iter()
            .any(|a| a.name == spec.source_aggregate
                && spec.source_context.as_ref().map_or(true, |ctx| {
                    a.context.as_ref().map_or(false, |c| c == ctx)
                })
                && a.queries.iter().any(|q| q.name == spec.query_name));

        if has_query {
            let attrs: HashMap<String, String> = HashMap::new();
            let json = self.resolve_query_qualified(
                spec.source_context.as_deref(),
                &spec.source_aggregate,
                &spec.query_name,
                &attrs,
            );
            let mut out = Vec::new();
            // resolve_query returns either an object (single match)
            // or an array under .state. Normalize.
            let state = json.get("state").cloned().unwrap_or(serde_json::Value::Null);
            match state {
                serde_json::Value::Array(arr) => {
                    for item in arr {
                        if let serde_json::Value::Object(map) = item {
                            out.push(json_obj_to_value_map(map));
                        }
                    }
                }
                serde_json::Value::Object(map) => {
                    out.push(json_obj_to_value_map(map));
                }
                _ => {}
            }
            return out;
        }

        // Fallback : enumerate all records of the source aggregate.
        // The aggregate-level specification (e.g. Synapse :cold) isn't
        // a first-class query yet ; sweeping `repo.all()` and letting
        // the receiving command's givens gate is the transitional
        // semantics. Receiving aggregates with `given` clauses will
        // short-circuit on records that don't qualify.
        self.all(&spec.source_aggregate)
            .iter()
            .map(|s| s.fields.clone())
            .collect()
    }

