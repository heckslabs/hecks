    /// Context+aggregate-qualified query resolution. When `context` is
    /// `Some(name)`, only aggregates whose `context` matches participate.
    /// When `aggregate` is non-empty, only aggregates with that name
    /// participate. Both filters together disambiguate name collisions
    /// across bluebooks (the i142 Context.Aggregate.Command frame
    /// applied to query lookups).
    ///
    /// `resolve_query` delegates here with `(None, "")` for the back-
    /// compat unqualified path.
    pub fn resolve_query_qualified(
        &self,
        context: Option<&str>,
        aggregate: &str,
        query_name: &str,
        attrs: &std::collections::HashMap<String, String>,
    ) -> serde_json::Value {
        // Walk the IR with the same (context, name) filter the qualified
        // dispatcher uses ; capture the matching aggregate's context so
        // the record retrieval below targets the SAME repo, not a
        // name-only lookup that picks one of several same-named
        // repositories non-deterministically (the dream_content_smoke
        // flake : Mind::Musing + Musing::Musing + Musings::Musing all
        // present, only Musings::Musing has the seeded records, but
        // self.all("Musing") returned an empty repo half the time).
        let (resolved_context, agg_name, _agg_refs, mut query_ir) = self.domain.aggregates.iter()
            .filter(|a| context.map_or(true, |ctx| {
                a.context.as_ref().map_or(false, |c| c == ctx)
            }))
            .filter(|a| aggregate.is_empty() || a.name == aggregate)
            .find_map(|a| a.queries.iter().find(|q| q.name == query_name)
                .map(|q| (a.context.clone(), a.name.clone(), a.references.clone(), q.clone())))
            .unwrap_or_else(|| (None, String::new(), Vec::new(), crate::ir::Query {
                name: query_name.to_string(),
                description: None,
                attributes: vec![],
                wheres: vec![],
                order_by: None,
                limit: None,
                reduction: None,
                group_by: None,
                scope_to: None,
            }));

    // SinceSequence addresses the NESTED `sequence` field ({"value": N}) the
    // where() DSL can't express portably (Ruby symbol syntax forbids `a.b:`),
    // so the runtime INJECTS the dotted range clause here and reuses the normal
    // seek + oracle path below. `:sequence` is a kwarg-ref resolved from attrs.
    // (AtSequence keeps its bluebook `where(sequence: seq)` so the in-memory
    // behaviors corpus, which stores the VO as a string, still matches it.)
    if query_name == "SinceSequence" {
        query_ir.wheres = vec![crate::ir::WhereClause {
            field: "sequence.value".to_string(),
            op: crate::ir::WhereOp::Gt,
            value: ":sequence".to_string(),
        }];
    }

    // scope_to (deciderate Layer 0a) — read-authZ row-scope. Inject a
    // where(<field> == :actor) clause resolved from the reserved `actor`
    // dispatch kwarg, exactly as SinceSequence injects its range clause.
    // The edge/ACL supplies actor=<id> ; absent it, :actor resolves to ""
    // and only unowned rows match. Appends to whatever wheres exist so it
    // composes with the query's own filters.
    if let Some(scope_field) = query_ir.scope_to.clone() {
        query_ir.wheres.push(crate::ir::WhereClause {
            field: scope_field,
            op: crate::ir::WhereOp::Eq,
            value: ":actor".to_string(),
        });
    }

        // MatchInput: search loaded commands by phrase
        if query_name == "MatchInput" {
            let input = attrs.get("input").map(|s| s.to_lowercase()).unwrap_or_default();
            let mut best_phrase = String::new();
            let mut best_agg = String::new();
            let mut best_cmd = String::new();
            let mut best_score: f64 = 0.0;
            for agg in &self.domain.aggregates {
                for cmd in &agg.commands {
                    let phrase = pascal_to_phrase(&cmd.name);
                    let score = trigram_sim(&input, &phrase);
                    if score > best_score {
                        best_score = score;
                        best_phrase = phrase;
                        best_agg = agg.name.clone();
                        best_cmd = cmd.name.clone();
                    }
                }
            }
            return serde_json::json!({
                "aggregate": agg_name, "query": query_name,
                "state": {
                    "match": if best_score > 0.3 { "found" } else { "none" },
                    "phrase": best_phrase, "aggregate": best_agg,
                    "command": best_cmd,
                    "confidence": format!("{:.0}", best_score * 100.0),
                }
            });
        }

        // LookupDoor (Macrophage::GovernedDoor): project the native->door map
        // from the command IR. Scan every command for the door whose
        // `redirects_native` list contains the queried tool, and return its
        // fully-qualified door command plus door_args derived from that
        // command's own attribute names. There is no stored map, no Register,
        // no fixtures — the map IS the `redirects_native` declarations on the
        // door commands. Scoped to the Macrophage context so it never shadows
        // a like-named query in another domain (the Governance::* LookupDoor
        // during the Stage-5 transition). Like MatchInput, a meta-query the
        // engine special-cases because a record-filter `where` cannot iterate
        // the IR's own command structure.
        if query_name == "LookupDoor" && resolved_context.as_deref() == Some("Macrophage") {
            let tool = attrs.get("tool").cloned().unwrap_or_default();
            for agg in &self.domain.aggregates {
                for cmd in &agg.commands {
                    if cmd.redirects_native.iter().any(|t| t == &tool) {
                        let ctx = agg.context.clone().unwrap_or_default();
                        let door = if ctx.is_empty() {
                            format!("{}.{}", agg.name, cmd.name)
                        } else {
                            format!("{}::{}.{}", ctx, agg.name, cmd.name)
                        };
                        let door_args = cmd.attributes.iter()
                            .map(|a| format!("{}=<{}>", a.name, a.name))
                            .collect::<Vec<_>>()
                            .join(", ");
                        return serde_json::json!({
                            "aggregate": agg_name, "query": query_name,
                            "state": {
                                "match": "found",
                                "tool": tool,
                                "door_equivalent": door,
                                "door_args": door_args,
                            }
                        });
                    }
                }
            }
            return serde_json::json!({
                "aggregate": agg_name, "query": query_name,
                "state": { "match": "none", "tool": tool }
            });
        }

        // CausationTrace: the recursive lineage walk a single where() cannot
        // express. From a root event_id, follow causation_id up the chain to the
        // root cause, accumulating each event in order. find() resolves each
        // event by id (Event is identified_by event_id) ; causation_id reads as
        // either a plain string or a {value} VO. A seen-set guards cycles ; the
        // walk stops at an empty causation_id or a missing event. Like
        // MatchInput, a named query the engine special-cases — not a
        // record-filter.
        if query_name == "CausationTrace" {
            let mut records: Vec<serde_json::Value> = Vec::new();
            let mut seen = std::collections::HashSet::new();
            let mut current = attrs.get("event_id").cloned().unwrap_or_default();
            while !current.is_empty() && seen.insert(current.clone()) {
                let ev = match self.find(&agg_name, &current) {
                    Some(e) => e,
                    None => break,
                };
                let cause = match ev.fields.get("causation_id") {
                    Some(Value::Str(s)) => s.clone(),
                    Some(Value::Map(m)) => {
                        m.get("value").map(|v| v.to_string()).unwrap_or_default()
                    }
                    _ => String::new(),
                };
                let mut map = serde_json::Map::new();
                for (k, v) in &ev.fields {
                    map.insert(k.clone(), match v {
                        Value::Str(s) => serde_json::json!(s),
                        Value::Int(n) => serde_json::json!(n),
                        Value::Bool(b) => serde_json::json!(b),
                        _ => serde_json::json!(v.to_string()),
                    });
                }
                records.push(serde_json::Value::Object(map));
                current = cause;
            }
            return serde_json::json!({
                "aggregate": agg_name, "query": query_name,
                "state": serde_json::json!(records),
            });
        }

        // Snapshot.ReadForward : fold the watermark TAIL forward onto the cached
        // snapshot. Load the Snapshot (cached rows + watermark), SEEK every Event
        // with sequence.value > watermark (the Event-Log sequence-range fast path,
        // via repo.query -> load_filtered), and apply those deltas forward
        // (last-write-wins). No snapshot yet -> watermark 0 -> a full replay. Serves
        // the trivial current-state projection (key "agg::id::field") ; a snapshot
        // is never wrong, only stale. A named query the engine special-cases.
        if query_name == "ReadForward" {
            let pname = attrs.get("projection_name").cloned().unwrap_or_default();
            let (mut rows, watermark): (std::collections::HashMap<String, String>, i64) =
                match self.find("Snapshot", &pname) {
                    Some(snap) => {
                        let wm = match snap.get("watermark") {
                            Value::Map(m) => m.get("value").and_then(|v| v.as_int()).unwrap_or(0),
                            Value::Int(i) => *i,
                            other => other.to_string().parse().unwrap_or(0),
                        };
                        let mut r = std::collections::HashMap::new();
                        if let Value::List(items) = snap.get("state") {
                            for it in items {
                                if let Value::Map(m) = it {
                                    let k = m.get("key").map(|v| v.to_string()).unwrap_or_default();
                                    let v = m.get("value").map(|v| v.to_string()).unwrap_or_default();
                                    if !k.is_empty() {
                                        r.insert(k, v);
                                    }
                                }
                            }
                        }
                        (r, wm)
                    }
                    None => (std::collections::HashMap::new(), 0),
                };
            // SEEK the tail : sequence.value > watermark (range fast path), then the
            // oracle re-filters — the same prefilter+oracle the generic path uses.
            let tail_wheres = vec![crate::ir::WhereClause {
                field: "sequence.value".to_string(),
                op: crate::ir::WhereOp::Gt,
                value: watermark.to_string(),
            }];
            let no_attrs = std::collections::HashMap::new();
            let owned = self
                .repositories
                .get(&repo_key(Some("EventSourcing"), "Event"))
                .and_then(|repo| repo.query(&tail_wheres, &no_attrs));
            let tail_refs: Vec<&AggregateState> = match owned {
                Some(ref o) => o.iter().collect(),
                None => self.all_qualified(Some("EventSourcing"), "Event"),
            };
            let tail: Vec<&AggregateState> = tail_refs
                .into_iter()
                .filter(|s| where_matches(s, &tail_wheres[0], &no_attrs))
                .collect();
            rows = super::projection_fold::fold_forward_onto(rows, &tail);
            let mut keys: Vec<&String> = rows.keys().collect();
            keys.sort();
            let out: Vec<serde_json::Value> = keys
                .iter()
                .map(|k| serde_json::json!({ "key": k, "value": rows.get(*k).unwrap() }))
                .collect();
            return serde_json::json!({
                "aggregate": agg_name, "query": query_name,
                "state": serde_json::json!(out),
            });
        }

        // Generic query: get the candidate set, then apply wheres / order_by /
        // limit. The backend may PREFILTER when the context is resolved — SQL at
        // the connection (injection-safe bound params, index-ready), the Event
        // Log via a filtered streaming scan (hydrate only matching lines). Either
        // way `where_matches` below re-applies EVERY clause, so a prefilter can
        // only narrow, never change, the result — parity by construction. A
        // backend with no pushdown (heki/memory, or no pushable clause) returns
        // None here and keeps the in-memory all() fast path (no clone), reached
        // via `all_qualified` so the (context, name) repo key is hit directly,
        // bypassing the name-only HashMap-iter-order pick that drove the
        // dream_content_smoke flake.
        let backend_candidates: Option<Vec<AggregateState>> = resolved_context.as_deref()
            .and_then(|ctx| self.repositories.get(&repo_key(Some(ctx), &agg_name)))
            .and_then(|repo| repo.query(&query_ir.wheres, attrs));
        let candidate_refs: Vec<&AggregateState> = match backend_candidates {
            Some(ref owned) => owned.iter().collect(),
            None => self.all_qualified(resolved_context.as_deref(), &agg_name),
        };
        let mut filtered: Vec<&AggregateState> = candidate_refs.into_iter()
            .filter(|s| query_ir.wheres.iter().all(|w| match w.op {
                crate::ir::WhereOp::NoneInState => {
                    // Cross-aggregate anti-join, point lookup. `field` is
                    // the candidate record's own id attribute ; `value` is
                    // "Aggregate:blocking_state". PASS when no foreign
                    // record exists for that id, or the one that exists is
                    // not in the blocking state.
                    let id = s.get(&w.field).to_string();
                    let (agg, blocking_state) = match w.value.split_once(':') {
                        Some((a, st)) => (a, st),
                        None => (w.value.as_str(), ""),
                    };
                    match self.find(agg, &id) {
                        None => true,
                        Some(r) => r.get("state").to_string() != blocking_state,
                    }
                }
                _ => where_matches(s, w, attrs),
            }))
            .collect();

        if let Some(ref ob) = query_ir.order_by {
            filtered.sort_by(|a, b| {
                let av = a.fields.get(&ob.field).map(|v| v.to_string()).unwrap_or_default();
                let bv = b.fields.get(&ob.field).map(|v| v.to_string()).unwrap_or_default();
                match ob.direction {
                    crate::ir::Direction::Asc  => av.cmp(&bv),
                    crate::ir::Direction::Desc => bv.cmp(&av),
                }
            });
        }

        if let Some(ref ls) = query_ir.limit {
            let cap = resolve_limit_value(&ls.value, attrs);
            if let Some(n) = cap {
                filtered.truncate(n);
            }
        }

        // Reductions + group_by (deciderate Layer 0a). When the query
        // declares a reduction or group_by, fold the matched / ordered /
        // limited set to a scalar (or per-group tally) INSTEAD of returning
        // records. A numeric read handles plain Int, a parseable Str, and
        // the single-value VO shape {value: N} — mirroring resolve_state_field.
        fn red_numeric(s: &AggregateState, field: &str) -> Option<f64> {
            fn from_value(v: &Value) -> Option<f64> {
                match v {
                    Value::Int(n) => Some(*n as f64),
                    Value::Str(s) => s.parse::<f64>().ok(),
                    Value::Map(m) => m.get("value").and_then(from_value),
                    _ => None,
                }
            }
            s.fields.get(field).and_then(from_value)
        }
        fn red_fmt(x: f64) -> serde_json::Value {
            // Integral results print as integers (count/sum/median of whole
            // numbers) ; fractional medians keep their decimal.
            if x.fract() == 0.0 { serde_json::json!(x as i64) } else { serde_json::json!(x) }
        }
        fn red_scalar(set: &[&AggregateState], red: &crate::ir::Reduction) -> serde_json::Value {
            use crate::ir::Reduction::*;
            match red {
                Count => serde_json::json!(set.len()),
                Sum(f) => red_fmt(set.iter().filter_map(|r| red_numeric(r, f)).sum()),
                Max(f) => set.iter().filter_map(|r| red_numeric(r, f))
                    .fold(None, |a: Option<f64>, x| Some(a.map_or(x, |v| v.max(x))))
                    .map(red_fmt).unwrap_or(serde_json::Value::Null),
                Min(f) => set.iter().filter_map(|r| red_numeric(r, f))
                    .fold(None, |a: Option<f64>, x| Some(a.map_or(x, |v| v.min(x))))
                    .map(red_fmt).unwrap_or(serde_json::Value::Null),
                Median(f) => {
                    let mut xs: Vec<f64> = set.iter().filter_map(|r| red_numeric(r, f)).collect();
                    xs.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
                    if xs.is_empty() { serde_json::Value::Null }
                    else if xs.len() % 2 == 1 { red_fmt(xs[xs.len() / 2]) }
                    else { red_fmt((xs[xs.len() / 2 - 1] + xs[xs.len() / 2]) / 2.0) }
                }
            }
        }
        fn red_label(red: &crate::ir::Reduction) -> &'static str {
            use crate::ir::Reduction::*;
            match red { Count => "count", Sum(_) => "sum", Max(_) => "max", Min(_) => "min", Median(_) => "median" }
        }

        if let Some(ref gb) = query_ir.group_by {
            // Partition by the field's value (BTreeMap = deterministic key
            // order) ; with a reduction fold each group, else count it.
            let mut groups: std::collections::BTreeMap<String, Vec<&AggregateState>> =
                std::collections::BTreeMap::new();
            for s in &filtered {
                let k = resolve_state_field(s, gb);
                groups.entry(k).or_default().push(s);
            }
            let mut out = serde_json::Map::new();
            for (k, members) in &groups {
                let v = match &query_ir.reduction {
                    Some(red) => red_scalar(members, red),
                    None => serde_json::json!(members.len()),
                };
                out.insert(k.clone(), v);
            }
            return serde_json::json!({
                "aggregate": agg_name, "query": query_name,
                "state": { "groups": serde_json::Value::Object(out) },
            });
        }
        if let Some(ref red) = query_ir.reduction {
            let mut obj = serde_json::Map::new();
            obj.insert(red_label(red).to_string(), red_scalar(&filtered, red));
            return serde_json::json!({
                "aggregate": agg_name, "query": query_name,
                "state": serde_json::Value::Object(obj),
            });
        }

        let records: Vec<serde_json::Value> = filtered.iter().map(|s| {
            let mut map = serde_json::Map::new();
            for (k, v) in &s.fields {
                map.insert(k.clone(), match v {
                    Value::Str(s) => serde_json::json!(s),
                    Value::Int(n) => serde_json::json!(n),
                    Value::Bool(b) => serde_json::json!(b),
                    _ => serde_json::json!(v.to_string()),
                });
            }
            serde_json::Value::Object(map)
        }).collect();
        serde_json::json!({
            "aggregate": agg_name, "query": query_name,
            "state": if records.len() == 1 { records[0].clone() } else { serde_json::json!(records) },
        })
    }
