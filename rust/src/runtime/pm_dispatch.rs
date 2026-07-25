//! pm_dispatch — the process-manager dispatch ENUMERATION : 
//! enumerate_pm_dispatches (the C3 capture-only twin of drain_policies' PM
//! block — runs the PM state machine, resolves each dispatch's attrs, hands
//! them back for the outbox to record as Steps) and pm_set_pairs (the Phase
//! 2.c `set` directive resolution on a firing trigger).
//!
//! Cask extracted VERBATIM from runtime/mod.rs (shrink-mod phase B, wave 3).
//!
//! [antibody-exempt: rust/src/runtime/pm_dispatch.rs — kernel-floor PM
//!  cascade enumeration (no bluebook can describe its own driver), relocated
//!  verbatim from mod.rs blanket.]

use super::*;

impl Runtime {
    /// C3 (transactional outbox) — enumerate the PM-driven dispatches for an
    /// event, returning (command, attrs) WITHOUT dispatching. Capture-only
    /// twin of the PM block in `drain_policies`: it runs the PM state machine
    /// (react + persist + set), because PM dispatches can't be enumerated
    /// without advancing the machine — that state evolution belongs to the
    /// PM's own aggregate. It then resolves each dispatch's attrs (for_each
    /// sweep + with_spec + inject_refs) exactly as the eager path does, and
    /// hands the resolved dispatches back for the outbox to record as Steps.
    /// Called ONLY on the deferred path (not the eager body hot path), so a
    /// divergence from drain_policies can never touch the live body.
    pub(super) fn enumerate_pm_dispatches(&mut self, event: &Event) -> Vec<(String, HashMap<String, Value>)> {
        let mut out: Vec<(String, HashMap<String, Value>)> = Vec::new();
        let pm_triggers = self.pm_engine.react(event);
        for t in pm_triggers.clone() {
            let _ = self.pm_engine.persist_instance(
                &t.pm_name,
                &t.correlation_id,
                self.data_dir.as_deref(),
            );
            let set_pairs = self.pm_set_pairs(&t, event);
            for (attr, value) in set_pairs {
                self.pm_engine
                    .apply_set(&t.pm_name, &t.correlation_id, &attr, value);
            }
            let _ = self.pm_engine.persist_instance(
                &t.pm_name,
                &t.correlation_id,
                self.data_dir.as_deref(),
            );
            for dispatched in &t.dispatches {
                let iter_records: Vec<HashMap<String, Value>> = match &dispatched.for_each {
                    Some(spec) => {
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
                    let mut data: HashMap<String, Value> = HashMap::new();
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
                    out.push((dispatched.command_name.clone(), data));
                }
            }
        }
        out
    }

    /// Phase 2.c — resolve every `set` directive on the firing
    /// handler into concrete (attr, String) pairs, ready to write to
    /// the PM instance. Reuses the same ValueSpec evaluator as the
    /// dispatch with-spec ; coerces the resolved Value to its
    /// Display form (matches the storage convention — attributes
    /// round-trip as JSON strings). Skips entries that resolve to
    /// None (no event match + no default = leave attr untouched).
    pub(super) fn pm_set_pairs(&self, t: &PMTrigger, event: &Event) -> Vec<(String, String)> {
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
}
