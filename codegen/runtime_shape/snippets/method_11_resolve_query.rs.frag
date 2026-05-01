    /// Resolve a query — search IR or return aggregate state.
    ///
    /// i101 — when the IR Query carries structured wheres / order_by /
    /// limit, the executor walks repo.all() and applies them in order :
    /// filter → sort → truncate. The opaque-Ruby-block era is retired.
    pub fn resolve_query(&self, query_name: &str, attrs: &std::collections::HashMap<String, String>) -> serde_json::Value {
        let (agg_name, query_ir) = self.domain.aggregates.iter()
            .find_map(|a| a.queries.iter().find(|q| q.name == query_name).map(|q| (a.name.clone(), q.clone())))
            .unwrap_or_else(|| (String::new(), crate::ir::Query {
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

        // Generic query: walk repo.all(), apply wheres / order_by / limit.
        let state = self.all(&agg_name);
        let mut filtered: Vec<&AggregateState> = state.into_iter()
            .filter(|s| query_ir.wheres.iter().all(|w| where_matches(s, w, attrs)))
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

