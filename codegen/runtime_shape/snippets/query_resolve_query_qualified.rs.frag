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
        let (resolved_context, agg_name, _agg_refs, query_ir) = self.domain.aggregates.iter()
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
            }));

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
