    /// Evaluate one with-spec entry into a runtime Value at PM
    /// dispatch time. Three kinds :
    ///
    ///   - `Literal { value }`             → `Value::Str(value)`
    ///   - `FromEvent { name, default }`    → `event.data[name]` ;
    ///                                        falls back to literal
    ///                                        from `default` ;
    ///                                        returns `None` when
    ///                                        both are absent.
    ///   - `FromPm { name, default }`       → `pm.attributes[name]` ;
    ///                                        same fallback semantics.
    ///
    /// Returns `None` when no value resolves (caller skips the key
    /// so the receiving aggregate sees no entry — same as if the
    /// dispatch never named it).
    ///
    /// Phase 2.c — FromPm now reads from the PM instance's
    /// `attributes` hash (populated by handlers' `set` directives).
    /// When the attribute is absent the spec's `default` fires ;
    /// when both are absent, returns None.
    fn evaluate_value_spec(
        &self,
        spec: &crate::ir::ValueSpec,
        event: &Event,
        pm_name: &str,
        correlation_id: &str,
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
            if let Some(v) = self.evaluate_value_spec(spec, event, &t.pm_name, &t.correlation_id) {
                out.push((attr.clone(), v.to_string()));
            }
        }
        out
    }

