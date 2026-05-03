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
                    // Phase 2.b (pm-dispatch-enrichment) — evaluate
                    // each ValueSpec in the with_spec at dispatch
                    // time. Order : with_spec resolution first (so an
                    // explicit `name: "body"` literal beats refs the
                    // inject_refs heuristic might guess), then
                    // upstream-ref injection fills in everything
                    // still unset.
                    let mut data = std::collections::HashMap::new();
                    for (key, spec) in &dispatched.with_spec {
                        if let Some(v) = self.evaluate_value_spec(
                            spec,
                            event,
                            &t.pm_name,
                            &t.correlation_id,
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
                    if let Ok(inner_result) = inner {
                        self.drain_policies(&inner_result);
                    }
                }
                self.pm_engine.complete(&t.pm_name);
            }

            let triggers = self.policy_engine.react(event);
            for trigger in triggers {
                let policy_name = trigger.policy_name.clone();
                let cmd = trigger.command_name.clone();
                let mut data = trigger.event_data.clone();

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
                if let Ok(inner_result) = inner {
                    self.drain_policies(&inner_result);
                }
                self.policy_engine.complete(&policy_name);
            }
        }
    }

