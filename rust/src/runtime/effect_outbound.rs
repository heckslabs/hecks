//! effect_outbound — the event-out EFFECT port pair : record_effect_outbound
//! (one durable OutboundEvent per subscribing standalone adapter, written on
//! emit — the out-of-process analog of cascade_record) and
//! has_effect_binding_for (the shape-derived keystone switch that suppresses
//! the in-process resolver when the OOP path owns a family's completion —
//! its exact complement).
//!
//! Cask extracted VERBATIM from runtime/mod.rs (shrink-mod phase B, wave 3).
//!
//! [antibody-exempt: rust/src/runtime/effect_outbound.rs — kernel-floor
//!  effect-port bookkeeping, relocated verbatim from mod.rs blanket.]

use super::*;

impl Runtime {
    /// Event-out messaging port (effect-port slice a) — record one durable
    /// `OutboundEvent` per standalone adapter that subscribes to this
    /// command's emitted event via an EFFECT binding (`Agg.charged_by("X",
    /// on: E, into: "Agg.Ok | Agg.No")`). The out-of-process analog of
    /// `record_cascade_run` : where that records IN-PROCESS domain reactions
    /// for the pump, this records OUT-OF-PROCESS deliveries for a separate-
    /// program host to consume. Runs on emit ; sync domain bookkeeping (the
    /// host does the async charge off-core). No-op when `OutboundEvent` isn't
    /// loaded or no effect binding names this event. delivery_id =
    /// source::id::event::adapter, so a re-emit is the same idempotent delivery.
    pub(super) fn record_effect_outbound(&mut self, result: &CommandResult) {
        let event = match &result.event {
            Some(e) => e.clone(),
            None => return,
        };
        // No substrate-presence guard : the outbox lives in the framework
        // collaborator, so it is ALWAYS available. This used to read "is
        // OutboundEvent in MY domain?", which is why the runtime had to graft
        // the outbox into every domain with an effect port (the graft is gone).
        // adapter -> family, family -> verb : the typed attach checkpoint, so a
        // broken bind records nothing (mirrors resolve_bindings' flat-map).
        let mut adapter_family: HashMap<String, String> = HashMap::new();
        let mut family_verb: HashMap<String, String> = HashMap::new();
        for hex in &self.hecksagons {
            for a in &hex.adapters {
                adapter_family.insert(a.name.clone(), a.family.clone());
            }
            for f in &hex.families {
                family_verb.insert(f.name.clone(), f.verb.clone());
            }
        }
        // Snapshot the Record attr-maps under the immutable borrow ; dispatch
        // after (dispatch_cascade takes &mut self).
        let mut records: Vec<HashMap<String, Value>> = Vec::new();
        // Bug B guard — the SAME binding seen twice across the loaded
        // hecksagons (a duplicate-loaded or re-declared hexagon) would record
        // the same delivery_id twice per emit, double-firing
        // OutboundEventRecorded. delivery_id IS the idempotency key, so record
        // each at most once per cascade. Distinct adapters keep distinct
        // delivery_ids (adapter name is in the key), so this only collapses
        // true duplicates — never a legitimate second subscriber.
        let mut seen_deliveries: std::collections::HashSet<String> =
            std::collections::HashSet::new();
        for hex in &self.hecksagons {
            for b in &hex.bindings {
                // Effect port subscribing to THIS event. A VERDICT bind
                // (charged_by) carries success/failure ; a FIRE-AND-FORGET bind
                // (voiced_by — speech is heard, not awaited) carries
                // neither. BOTH record an OutboundEvent and BOTH are consumed by
                // the host ; fire-and-forget simply dispatches no verdict on
                // delivery. Persistence binds (persisted_by) carry no `on`, so
                // they never match an event name here.
                if b.on != event.name {
                    continue;
                }
                match adapter_family.get(&b.adapter) {
                    Some(fam)
                        if family_verb.get(fam).map(String::as_str)
                            == Some(b.verb.as_str()) => {}
                    _ => continue,
                }
                // Verdict commands are `Aggregate.Command` ; prepend the bind's
                // context to form the dispatch FQN the host will re-enter with.
                let context = b.aggregate.rsplit_once("::").map(|(c, _)| c).unwrap_or("");
                let qualify = |cmd: &str| {
                    if context.is_empty() {
                        cmd.to_string()
                    } else {
                        format!("{}::{}", context, cmd)
                    }
                };
                // Guard BOTH verdicts : a fire-and-forget bind has empty
                // success/failure, and qualify("") would wrongly yield
                // "Context::". Empty stays empty so the host takes the
                // fire-and-forget path (dispatch no verdict).
                let success = if b.success.is_empty() { String::new() } else { qualify(&b.success) };
                let failure = if b.failure.is_empty() { String::new() } else { qualify(&b.failure) };
                let mut data_obj = serde_json::Map::new();
                for (k, v) in &event.data {
                    data_obj.insert(k.clone(), value_to_json(v));
                }
                let payload = serde_json::Value::Object(data_obj).to_string();
                let delivery_id = format!(
                    "{}::{}::{}::{}",
                    event.aggregate_type, event.aggregate_id, event.name, b.adapter
                );
                // Bug B — skip a delivery_id already recorded this cascade.
                if !seen_deliveries.insert(delivery_id.clone()) {
                    continue;
                }
                let mut attrs = HashMap::new();
                attrs.insert("delivery_id".to_string(), Value::Str(delivery_id));
                attrs.insert("adapter".to_string(), Value::Str(b.adapter.clone()));
                attrs.insert("event".to_string(), Value::Str(event.name.clone()));
                attrs.insert("source_type".to_string(), Value::Str(event.aggregate_type.clone()));
                attrs.insert("source_id".to_string(), Value::Str(event.aggregate_id.clone()));
                attrs.insert("payload".to_string(), Value::Str(payload));
                attrs.insert("success_command".to_string(), Value::Str(success));
                attrs.insert("failure_command".to_string(), Value::Str(failure));
                attrs.insert("attempts".to_string(), Value::Int(0));
                records.push(attrs);
            }
        }
        for attrs in records {
            // Record into the FRAMEWORK COLLABORATOR. The outbox is kernel
            // substrate, not a user aggregate — the domain that emitted the
            // event never needs to carry it.
            let agg_type = event.aggregate_type.clone();
            let agg_id = event.aggregate_id.clone();
            let fw = self.framework_mut();
            let _ = command_dispatch::dispatch_cascade(
                fw,
                "Hecks::Framework::Hexagon::OutboundEvent::OutboundEvent.Record",
                attrs,
                &agg_type,
                &agg_id,
            );
        }
    }

    /// Shape-derived OOP switch — the COMPLEMENT of `record_effect_outbound`'s
    /// match. Returns true iff some hecksagon binding subscribes (`on:`) to
    /// `event_name`, resolves adapter -> family -> verb to the NAMED `family`,
    /// AND is VERDICT-BEARING (`!b.success.is_empty()`). When true, the
    /// out-of-process effect path (effect binding -> OutboundEvent ->
    /// drain_outbound_to_quiescence) owns this family's completion, so the
    /// in-process resolver SUPPRESSES itself — the two never both fire and
    /// double-produce the verdict.
    ///
    /// INVARIANT : fires iff `record_effect_outbound` would have recorded a
    /// verdict-bearing OutboundEvent for the same dispatch. PURE SHAPE — it does
    /// NOT condition on the handler binary existing (that runtime state lives only
    /// in the drain's `actionable` filter, which leaves an unbuilt handler
    /// PENDING ; folding it in here would leak runtime state into a shape-derived
    /// switch and could strand a verdict). The fire-and-forget guard
    /// (`!b.success.is_empty()`) ensures a verdict-less binding (tts) can never
    /// suppress-then-strand the in-process path.
    pub fn has_effect_binding_for(&self, event_name: &str, family: &str) -> bool {
        if event_name.is_empty() {
            return false;
        }
        // adapter -> family, family -> verb : the same typed attach checkpoint
        // record_effect_outbound uses, so a broken bind matches nothing.
        let mut adapter_family: HashMap<String, String> = HashMap::new();
        let mut family_verb: HashMap<String, String> = HashMap::new();
        for hex in &self.hecksagons {
            for a in &hex.adapters {
                adapter_family.insert(a.name.clone(), a.family.clone());
            }
            for f in &hex.families {
                family_verb.insert(f.name.clone(), f.verb.clone());
            }
        }
        for hex in &self.hecksagons {
            for b in &hex.bindings {
                if b.on != event_name {
                    continue;
                }
                // Verdict-bearing only — a fire-and-forget bind (empty success)
                // records an OutboundEvent but dispatches no verdict, so it must
                // NOT suppress the in-process path (would strand the result).
                if b.success.is_empty() {
                    continue;
                }
                // adapter -> its family must be the NAMED family, and the bind's
                // verb must be that family's verb (the typed attach).
                let fam = match adapter_family.get(&b.adapter) {
                    Some(f) => f,
                    None => continue,
                };
                if fam != family {
                    continue;
                }
                if family_verb.get(fam).map(String::as_str) == Some(b.verb.as_str()) {
                    return true;
                }
            }
        }
        false
    }
}
