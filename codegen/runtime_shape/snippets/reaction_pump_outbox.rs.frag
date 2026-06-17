    /// C2 (transactional outbox) — drain the persistent CascadeRun outbox.
    /// Reads every Active run (status running) and delivers its steps: each
    /// step's command is dispatched as its OWN transaction — separate from
    /// the command that enqueued it, on this (later) tick — then the run is
    /// Completed. Idempotent at the run grain: a Completed run is no longer
    /// Active, so it is never re-delivered. Per-step status/retry awaits the
    /// list-element-update primitive (P0.1). Returns the number of runs
    /// drained. The pump is the ONLY thing that turns an outbox entry into a
    /// sibling mutation — across a transaction boundary, never inline.
    pub fn pump_outbox(&mut self) -> usize {
        if !self.domain.aggregates.iter().any(|a| a.name == "CascadeRun") {
            return 0;
        }
        // Flatten multi-hop cascades : deliver every Active run, RE-RECORD
        // each step's own domain reactions to the outbox, and loop until no
        // Active runs remain. Without the loop + re-record, only level-1
        // reactions fire (a policy on a cascaded event never triggers).
        let mut drained = 0;
        let mut guard = 0;
        loop {
            guard += 1;
            if guard > 10_000 {
                eprintln!("[pump_outbox] cascade guard reached — stopping");
                break;
            }
            let runs: Vec<(String, Vec<(String, String)>)> = self
                .all_qualified(Some("CascadeRun"), "CascadeRun")
                .into_iter()
                .filter(|r| {
                    r.fields.get("status").map(|v| v.to_string()).as_deref() == Some("running")
                })
                .map(|r| {
                    let mut steps: Vec<(i64, String, String)> = vec![];
                    if let Some(Value::List(items)) = r.fields.get("steps") {
                        for it in items {
                            if let Value::Map(m) = it {
                                let cmd = m.get("command").map(|v| v.to_string()).unwrap_or_default();
                                let payload =
                                    m.get("payload").map(|v| v.to_string()).unwrap_or_default();
                                let order = match m.get("order") {
                                    Some(Value::Int(n)) => *n,
                                    _ => 0,
                                };
                                steps.push((order, cmd, payload));
                            }
                        }
                    }
                    steps.sort_by_key(|(o, _, _)| *o);
                    (
                        r.id.clone(),
                        steps.into_iter().map(|(_, c, p)| (c, p)).collect(),
                    )
                })
                .collect();
            if runs.is_empty() {
                break;
            }
            for (run_id, steps) in runs {
                // Decode the upstream the run_id carries (type::id::event) so each
                // step dispatches against the ORIGINAL triggering aggregate as
                // upstream — exactly the eager path — letting reference_to(target)
                // resolve in dispatch_inner (e.g. Lease.Reclaim's reference_to(Lease)).
                let mut up = run_id.splitn(3, "::");
                let up_type = up.next().unwrap_or("").to_string();
                let up_id = up.next().unwrap_or("").to_string();
                for (command, payload) in steps {
                    if command.is_empty() {
                        continue;
                    }
                    let step_attrs = parse_payload_attrs(&payload);
                    // Deliver the step as its own transaction, and RE-RECORD its
                    // own domain reactions so multi-hop cascades flatten across
                    // iterations (level N -> level N+1).
                    let port_attrs = step_attrs.clone();
                    if let Ok(r) = command_dispatch::dispatch_cascade(
                        self, &command, step_attrs, &up_type, &up_id,
                    ) {
                        self.record_cascade_run(&r);
                        // Fire the impure adapter edge (compute / llm / claude_tool
                        // / mcp / web / spawn / tts) for THIS delivered step, exactly
                        // as the top-level eager dispatch does after record_cascade_run
                        // (mod.rs dispatch -> react_ports). Without this, a PM- or
                        // policy-driven step that targets an :llm adapter (e.g. the
                        // Dream PM's `Dream.ProduceImage` -> :dream_image) mutates
                        // aggregate state but NEVER fires its port when delivered via
                        // the outbox pump — the dream is recorded as a pending step
                        // and the reading is never generated. The bare step command
                        // ("Dream.ProduceImage") is the address resolve_* match on.
                        self.react_ports(&r, &command, &port_attrs);
                    }
                }
                let mut ca = HashMap::new();
                ca.insert("run_id".to_string(), Value::Str(run_id.clone()));
                let _ = command_dispatch::dispatch_cascade(
                    self,
                    "CascadeRun::CascadeRun.Complete",
                    ca,
                    "CascadeRun",
                    &run_id,
                );
                drained += 1;
            }
        }
        drained
    }
