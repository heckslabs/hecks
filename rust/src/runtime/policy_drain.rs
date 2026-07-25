//! policy_drain — drain_policies, the LIVE policy/PM cascade loop : each
//! triggered command can emit events that trigger more policies (EnterSleep
//! cascading through 8 dream cycles to WakeUp). The capture-only twin is
//! pm_dispatch::enumerate_pm_dispatches ; the with-spec resolution it shares
//! lives in policy_cascade.rs.
//!
//! Cask extracted VERBATIM from runtime/mod.rs (shrink-mod phase B, wave 3).
//!
//! [cask-irreducible: policy_drain.rs — a single 230-line interpreter fn
//!  (the live policy/PM cascade loop); splitting it means carving helpers
//!  out of live cascade logic, which the pure-move discipline forbids.
//!  Signed by Chris, 2026-07-25.]
//!
//! [antibody-exempt: rust/src/runtime/policy_drain.rs — kernel-floor
//!  interpreter loop (no bluebook can describe its own driver), relocated
//!  verbatim from mod.rs blanket.]

use super::*;

impl Runtime {
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
    pub(crate) fn drain_policies(&mut self, result: &CommandResult) {
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
                        Some(spec) => {
                            // i221-C — resolve the swept query's inputs
                            // against the event so the sweep filters.
                            let mut q_attrs: HashMap<String, String> = HashMap::new();
                            for (k, vspec) in &spec.query_inputs {
                                if let Some(v) = self.evaluate_value_spec(
                                    vspec, event, &t.pm_name, &t.correlation_id, None,
                                ) {
                                    q_attrs.insert(k.clone(), v.to_string());
                                }
                            }
                            self.sweep_records(spec, &q_attrs)
                        }
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
                        // Clone before the move so the process-spawn
                        // primitive hook below sees the dispatch attrs
                        // (a PM could also drive Primitive::Process.Spawn).
                        let cascade_attrs = data.clone();
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
                            // Process-spawn primitive on PM cascades —
                            // same hook as the policy arm below.
                            self.resolve_primitive_spawn(
                                &inner_result, &dispatched.command_name, &cascade_attrs,
                                Some(event),
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

                // deciderate Layer 0b — fan out the primary trigger when the
                // policy declares `for_each: { from: "Agg.query" }` : sweep the
                // query and fire `cmd` once per record, merging the record's
                // fields into the dispatch data. No for_each = a single pass.
                let primary_records: Vec<HashMap<String, Value>> = match &trigger.for_each {
                    Some(spec) => {
                        let mut q_attrs: HashMap<String, String> = HashMap::new();
                        for (k, vspec) in &spec.query_inputs {
                            if let Some(v) = self.evaluate_value_spec(vspec, event, "", "", None) {
                                q_attrs.insert(k.clone(), v.to_string());
                            }
                        }
                        self.sweep_records(spec, &q_attrs)
                    }
                    None => vec![HashMap::new()],
                };
                let primary_sweep = trigger.for_each.is_some();
                for primary_record in &primary_records {
                    // event data, then the policy's `with` literals (which win),
                    // then the swept record's fields (the fan-out binding).
                    let mut data = trigger.event_data.clone();
                    for (k, v) in &trigger.with_data {
                        data.insert(k.clone(), v.clone());
                    }
                    if primary_sweep {
                        for (k, v) in primary_record {
                            data.insert(k.clone(), v.clone());
                        }
                    }
                    storehouse_log::policy_reaction(
                        &policy_name,
                        &event.aggregate_type,
                        &event.name,
                        &event.aggregate_id,
                        &cmd,
                    );
                    self.fire_policy_cascade(&cmd, data, event);
                }

                // deciderate Layer 0b — extra reactions : each `dispatch "Cmd",
                // with: {..}, for_each: {..}` fires after the primary trigger,
                // reusing the same sweep + with-spec machinery as PM dispatches.
                for dispatched in &trigger.extra_dispatches {
                    let iter_records: Vec<HashMap<String, Value>> = match &dispatched.for_each {
                        Some(spec) => {
                            let mut q_attrs: HashMap<String, String> = HashMap::new();
                            for (k, vspec) in &spec.query_inputs {
                                if let Some(v) = self.evaluate_value_spec(vspec, event, "", "", None) {
                                    q_attrs.insert(k.clone(), v.to_string());
                                }
                            }
                            self.sweep_records(spec, &q_attrs)
                        }
                        None => vec![HashMap::new()],
                    };
                    let is_sweep = dispatched.for_each.is_some();
                    for record in &iter_records {
                        let iter_arg = if is_sweep { Some(record) } else { None };
                        let mut data: HashMap<String, Value> = HashMap::new();
                        for (key, spec) in &dispatched.with_spec {
                            if let Some(v) = self.evaluate_value_spec(spec, event, "", "", iter_arg) {
                                data.insert(key.clone(), v);
                            }
                        }
                        self.fire_policy_cascade(&dispatched.command_name, data, event);
                    }
                }

                self.policy_engine.complete(&policy_name);
            }
        }
    }
}
