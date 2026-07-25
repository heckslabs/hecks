//! cascade_record — the C2 transactional outbox WRITER : one durable
//! CascadeRun (steps = the event-reaction payloads) recorded in the same
//! transaction as the dispatch, for deliver_cascade_runs (reaction.rs) to
//! deliver on a later tick. Falls back to the in-memory PendingReaction
//! outbox when CascadeRun is not loaded — held until pump, never dropped.
//!
//! Cask extracted VERBATIM from runtime/mod.rs (shrink-mod phase B, wave 3).
//!
//! [antibody-exempt: rust/src/runtime/cascade_record.rs — kernel-floor
//!  outbox writer (the PM cascade cannot bluebook its own driver), relocated
//!  verbatim from mod.rs blanket.]

use super::*;

impl Runtime {
    /// Transactional outbox — when a dispatched command's event has domain
    /// reactions (policy triggers, driven-adapter dispatches, PM dispatches),
    /// write a persistent `CascadeRun.Begin` recording them as ordered Steps.
    /// The outbox IS the async delivery queue : pump_outbox drains each step
    /// as its own transaction on a later tick. No-op when the CascadeRun
    /// aggregate isn't loaded or the event has no reactions (the caller then
    /// falls back to the in-memory pump).
    pub(super) fn record_cascade_run(&mut self, result: &CommandResult) -> bool {
        let event = match &result.event {
            Some(e) => e.clone(),
            None => return false,
        };
        if !self.domain.aggregates.iter().any(|a| a.name == "CascadeRun") {
            return false;
        }
        // Reactions = (command, payload_json). Each payload is resolved
        // EXACTLY as the eager path would, so the pump's later dispatch sees
        // the same attrs. Policy triggers: event data + `with` literals, then
        // inject_refs so the triggered command's reference_to resolves.
        let mut reactions: Vec<(String, String)> = Vec::new();
        // Policy triggers. Capture through policy_engine.react so the in_flight
        // reentrancy guard breaks cyclic cascades (a re-entrant policy within
        // this pump session is skipped) ; in_flight is not cleared here — the
        // fork-per-dispatch process boundary resets it.
        // (target command, resolved attrs, the event data it resolved from).
        type ResolvedPolicyDispatch = (String, HashMap<String, Value>, HashMap<String, Value>);
        let policy_resolved: Vec<ResolvedPolicyDispatch> = self
            .policy_engine
            .react(&event)
            .into_iter()
            .map(|t| {
                let mut data = t.event_data.clone();
                for (k, v) in &t.with_data {
                    data.insert(k.clone(), v.clone());
                }
                (t.command_name.clone(), data, t.with_data)
            })
            .collect();
        for (cmd, mut data, with_data) in policy_resolved {
            // inject_refs matches the BARE command name (DropPendingTaskCount),
            // not the FQN (Story.DropPendingTaskCount) the policy binding carries.
            // Strip the aggregate prefix so the reference_to target resolves into
            // the payload HERE — the pump dispatches with a CascadeRun upstream, so
            // the payload must already carry every ref (the eager path resolves it
            // from the real upstream inside dispatch_inner instead).
            let bare = cmd.rsplit('.').next().unwrap_or(&cmd).to_string();
            self.inject_refs(&bare, &event.aggregate_type, &event.aggregate_id, &mut data);
            // A policy's explicit `with` pairs are INTENT, never upstream leak —
            // re-assert them AFTER inject_refs, whose identified_by heuristic
            // (i151 leak-removal) strips an identity key that names a record not
            // existing yet. An establishment cascade (the authz roster on
            // BootCompleted) supplies exactly such a key to CREATE the record ;
            // without this re-assert the outbox payload lost auth_identity_id /
            // id and the roster collapsed into one junk counter-minted row
            // (FINDING-keystone-dead-path). The eager path never stripped them :
            // fire_policy_cascade passes the QUALIFIED command name, which
            // inject_refs doesn't match — this aligns the outbox path with it.
            for (k, v) in with_data {
                data.insert(k, v);
            }
            let mut obj = serde_json::Map::new();
            for (k, v) in &data {
                obj.insert(k.clone(), value_to_json(v));
            }
            reactions.push((cmd, serde_json::Value::Object(obj).to_string()));
        }
        for (cmd, attr_map) in driven_adapter_resolver::enumerate_driven_dispatches(self, &event) {
            let mut obj = serde_json::Map::new();
            for (k, v) in &attr_map {
                obj.insert(k.clone(), value_to_json(v));
            }
            reactions.push((cmd, serde_json::Value::Object(obj).to_string()));
        }
        // PM-driven reactions. enumerate_pm_dispatches advances the PM state
        // machine ; each PM dispatch carries its own resolved attrs (for_each
        // sweep + with_spec + inject_refs).
        for (cmd, attr_map) in self.enumerate_pm_dispatches(&event) {
            let mut obj = serde_json::Map::new();
            for (k, v) in &attr_map {
                obj.insert(k.clone(), value_to_json(v));
            }
            reactions.push((cmd, serde_json::Value::Object(obj).to_string()));
        }
        if reactions.is_empty() {
            return false;
        }
        let steps: Vec<Value> = reactions
            .iter()
            .enumerate()
            .map(|(i, (cmd, payload))| {
                let mut m = HashMap::new();
                m.insert("ref".to_string(), Value::Str(format!("step-{}", i + 1)));
                m.insert("command".to_string(), Value::Str(cmd.clone()));
                m.insert("order".to_string(), Value::Int((i as i64) + 1));
                m.insert("status".to_string(), Value::Str("pending".to_string()));
                m.insert("attempt".to_string(), Value::Int(0));
                m.insert("last_error".to_string(), Value::Str(String::new()));
                m.insert("payload".to_string(), Value::Str(payload.clone()));
                Value::Map(m)
            })
            .collect();
        // run_id encodes the upstream so the pump can dispatch each step with
        // the ORIGINAL triggering aggregate as upstream (== the eager path),
        // letting reference_to(SameAggregate) resolve via dispatch_inner.
        let run_id = format!("{}::{}::{}", event.aggregate_type, event.aggregate_id, event.name);
        let mut retry = HashMap::new();
        retry.insert("max_attempts".to_string(), Value::Int(0));
        retry.insert("backoff".to_string(), Value::Str("none".to_string()));
        // Phase-4 causation : the triggering event's Log event_id is the cause
        // of every step in this run. note_last_event recorded it under the
        // trigger aggregate's key when record_event_append ran for the trigger
        // (just before this). Persist it on the run so the pump stamps it
        // DURABLY — even when a DIFFERENT process drains the outbox, where the
        // in-memory map is empty.
        let causation = self.last_event_id_by_agg
            .get(&format!("{}::{}", event.aggregate_type, event.aggregate_id))
            .cloned()
            .unwrap_or_default();
        let mut attrs = HashMap::new();
        attrs.insert("run_id".to_string(), Value::Str(run_id));
        attrs.insert("trigger_event".to_string(), Value::Str(event.name.clone()));
        attrs.insert("steps".to_string(), Value::List(steps));
        attrs.insert("retry_policy".to_string(), Value::Map(retry));
        attrs.insert("causation".to_string(), Value::Str(causation));
        let agg_type = event.aggregate_type.clone();
        let agg_id = event.aggregate_id.clone();
        let _ = command_dispatch::dispatch_cascade(
            self,
            "Hecks::Framework::Cascade::CascadeRun::CascadeRun.Begin",
            attrs,
            &agg_type,
            &agg_id,
        );
        true
    }

}
