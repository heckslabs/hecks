    /// Drain policy triggers recursively — each triggered command
    /// can emit events that trigger more policies. This is how
    /// EnterSleep cascades through 8 dream cycles to WakeUp.
    ///
    /// When the triggered command has a self-reference to the same
    /// aggregate the event came from, inject the upstream aggregate_id
    /// under that ref's name. Without this, downstream cascades stop
    /// at any self-ref command (the dispatch errors with missing
    /// self-referencing id), leaving aggregates stuck mid-pipeline.
    /// The behaviors generator's static cascade prediction
    /// (cascade::cascade_emits) assumes the runtime honors these
    /// triggers — so this injection is what makes the prediction true.
    fn drain_policies(&mut self, result: &CommandResult) {
        if let Some(ref event) = result.event {
            // Drive process_managers + dispatch their declared commands.
            // Each PMTrigger carries dispatches: Vec<String> populated
            // from the handler's declarative `dispatch "..."` lines ;
            // route through cascade dispatcher so policies + nested PMs
            // + downstream emits all fire normally.
            let pm_triggers = self.pm_engine.react(event);
            for t in pm_triggers.clone() {
                // Phase D — persist the new instance state immediately
                // after each transition so the next subprocess fork sees
                // it. Best-effort : a failed write doesn't abort the
                // cascade ; the audit trail captures it via heki's
                // dispatch context.
                let _ = self.pm_engine.persist_instance(
                    &t.pm_name,
                    &t.correlation_id,
                    self.data_dir.as_deref(),
                );

                // Phase 2.c — apply the handler's set_specs BEFORE the
                // dispatches so that `from_pm(:attr)` reads inside the
                // same handler's dispatch with-spec see the freshly
                // written value. This matches the legacy proc form
                // where the action body assigned `pm.attributes[:x]`
                // at the top, then returned `{ commands: [...] }`
                // referring to those same values.
                let set_pairs = self.pm_set_pairs(&t, event);
                for (attr, value) in set_pairs {
                    self.pm_engine
                        .apply_set(&t.pm_name, &t.correlation_id, &attr, value);
                }
                // Re-persist after the set so the attributes hash
                // round-trips with the new values. Best-effort, like
                // the state-only persist above.
                let _ = self.pm_engine.persist_instance(
                    &t.pm_name,
                    &t.correlation_id,
                    self.data_dir.as_deref(),
                );

                for dispatched in &t.dispatches {
                    // i221-B — sweep dispatch. When the DispatchSpec
                    // carries `for_each: Some(spec)`, look up the
                    // named query (Aggregate.query_name) in the
                    // domain IR, run it against the in-memory
                    // repository to enumerate matching records, and
                    // dispatch one cascade per record threading the
                    // record's fields as `iter_data`. `from_iter
                    // (:field)` in the with-spec resolves against
                    // each record. When `for_each` is `None` (the
                    // bare-dispatch path), the loop body runs once
                    // with `iter_data = None` — same shape as before.
                    let iter_records: Vec<HashMap<String, Value>> = match &dispatched.for_each {
                        Some(spec) => self.sweep_records(spec),
                        None => vec![HashMap::new()],
                    };
                    let is_sweep = dispatched.for_each.is_some();

                    for record in &iter_records {
                        // Phase 2.b (pm-dispatch-enrichment) —
                        // evaluate each ValueSpec in the with_spec
                        // at dispatch time. Order : with_spec
                        // resolution first (so an explicit
                        // `name: "body"` literal beats refs the
                        // inject_refs heuristic might guess), then
                        // upstream-ref injection fills in
                        // everything still unset.
                        let mut data = std::collections::HashMap::new();
                        let iter_arg = if is_sweep { Some(record) } else { None };
                        for (key, spec) in &dispatched.with_spec {
                            if let Some(v) = self.evaluate_value_spec(
                                spec,
                                event,
                                &t.pm_name,
                                &t.correlation_id,
                                iter_arg,
                            ) {
                                data.insert(key.clone(), v);
                            }
                        }
                        self.inject_refs(
                            &dispatched.command_name,
                            &event.aggregate_type,
                            &event.aggregate_id,
                            &mut data,
                        );
                        let inner = command_dispatch::dispatch_cascade(
                            self,
                            &dispatched.command_name,
                            data,
                            &event.aggregate_type,
                            &event.aggregate_id,
                        );
                        // i622 — cascade step log. PM-driven cascade.
                        storehouse_log::cascade_step(
                            &dispatched.command_name,
                            &event.aggregate_id,
                            inner.is_ok(),
                        );
                        if let Ok(inner_result) = inner {
                            self.drain_policies(&inner_result);
                            // i220 sub-gap 5 — fire the :compute hook
                            // on PM cascade dispatches first, so the
                            // chained context-populated state is
                            // visible when the LLM hook reads from
                            // the same target's state below.
                            self.resolve_compute_adapters(
                                &inner_result, &dispatched.command_name,
                            );
                            // i220-1 — fire the :llm hook on cascade
                            // dispatches the same way `Runtime::dispatch`
                            // fires it after top-level dispatch settles.
                            // Without this, PM-driven cascades (Dream PM
                            // dispatching Dream.RecordImage, etc.) never
                            // reach the named-adapter pipeline that wires
                            // `:dream_image` / `:dream_translate` to
                            // Claude. The recursion is bounded : the
                            // LLM hook itself uses `dispatch_cascade`
                            // (not `Runtime::dispatch`), so the response
                            // chain is one-shot per match — same shape
                            // the top-level call already relies on.
                            self.resolve_llm_adapters(
                                &inner_result, &dispatched.command_name,
                            );
                        }
                    }
                }
                self.pm_engine.complete(&t.pm_name);
            }

            let triggers = self.policy_engine.react(event);
            for trigger in triggers {
                let policy_name = trigger.policy_name.clone();
                let cmd = trigger.command_name.clone();
                let mut data = trigger.event_data.clone();

                // i622 — policy reaction log. Printed at every level
                // (including quiet) because policy chains are the
                // operational signal operators most often want to see.
                storehouse_log::policy_reaction(
                    &policy_name,
                    &event.aggregate_type,
                    &event.name,
                    &event.aggregate_id,
                    &cmd,
                );

                // Inject every reference the triggered command needs:
                //   1. self-ref or upstream-ref → use upstream event's aggregate_id
                //   2. other refs → use any record currently in that repo (singleton)
                // This makes static cascade prediction work across aggregate
                // boundaries: a policy chain can hop A→B→C even when neither
                // B nor C's input attrs were in the original test command.
                self.inject_refs(&cmd, &event.aggregate_type, &event.aggregate_id, &mut data);

                // i111-K — pass the upstream type+id as a cascade hint.
                // When the triggered command's aggregate matches
                // upstream_type AND a record exists at upstream_id, the
                // cascade preserves the id rather than counter-minting
                // a fresh one. This closes the i111-C surprise where
                // multi-step pipeline roots had to declare
                // `identified_by` just to keep gated cascades landing
                // on the same row. Cross-type cascades (A → B) and
                // cases without an existing record fall through to
                // standard resolution unchanged.
                let inner = command_dispatch::dispatch_cascade(
                    self, &cmd, data,
                    &event.aggregate_type, &event.aggregate_id,
                );
                // i622 — cascade step log. Policy-driven cascade.
                storehouse_log::cascade_step(
                    &cmd, &event.aggregate_id, inner.is_ok(),
                );
                if let Ok(inner_result) = inner {
                    self.drain_policies(&inner_result);
                    // i220 sub-gap 5 — :compute hook on policy
                    // cascades. Same ordering as the PM arm above :
                    // compute first (populates fields), then LLM
                    // (reads them in the prompt template).
                    self.resolve_compute_adapters(&inner_result, &cmd);
                    // i220-1 — same cascade-LLM hook as the PM-dispatch
                    // arm above. Policy-driven cascades (react_to /
                    // policy.bluebook) need the named-adapter pipeline
                    // too. Without this, any policy chain landing on
                    // `Dream.RecordImage` (or any other adapter target)
                    // would silently skip Claude.
                    self.resolve_llm_adapters(&inner_result, &cmd);
                }
                self.policy_engine.complete(&policy_name);
            }
        }
    }

