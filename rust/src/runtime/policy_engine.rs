//! PolicyEngine — reactive event→command wiring
//!
//! Policies subscribe to events and trigger follow-up commands.
//! Reentrant execution is prevented by tracking in-flight policies.
//!
//! Usage:
//!   engine.register("OnPizzaCreated", "PizzaCreated", "NotifyChef");
//!   let triggers = engine.react(&event);

use super::Event;
use crate::ir::{ValueSpec, WhereClause, ForEachSpec, DispatchSpec};
use std::collections::{HashMap, HashSet};

#[derive(Debug, Clone)]
pub struct PolicyBinding {
    pub name: String,
    pub on_event: String,
    /// gap #1b — bare event name (qualifier stripped). The `by_event`
    /// index keys on this so a qualified subscription still buckets
    /// under the event's name ; the qualifier is then checked against
    /// the firing event's `aggregate_type` in `react`.
    pub event_name: String,
    /// gap #1b — `Some(agg)` when the policy was declared
    /// `on "Aggregate.Event"`. The binding then fires ONLY for events
    /// of `event_name` emitted by `agg`. `None` (the bare `on "Event"`
    /// form) matches by name across every aggregate — the historical,
    /// backward-compatible behaviour.
    pub qualifier: Option<String>,
    pub trigger_command: String,
    /// Gap #1 (adapters-as-bluebook) — literal args the policy passes
    /// to its triggered command on top of the event's data. Resolved
    /// at react time and surfaced on the PolicyTrigger as `with_data`,
    /// which `drain_policies` merges into the dispatch data (winning
    /// over event data) before `inject_refs`. For this slice only
    /// `ValueSpec::Literal` is produced ; state-aware specs deferred.
    pub with: Vec<(String, ValueSpec)>,
    /// deciderate Layer 0b — data guard ; the policy fires only when EVERY
    /// clause matches the triggering event's data (evaluated in `react`).
    pub wheres: Vec<WhereClause>,
    /// deciderate Layer 0b — fan-out the primary trigger over a query ;
    /// the caller sweeps it (react has no &Runtime).
    pub for_each: Option<ForEachSpec>,
    /// deciderate Layer 0b — extra reactions beyond the primary trigger.
    pub extra_dispatches: Vec<DispatchSpec>,
}

pub struct PolicyEngine {
    bindings: Vec<PolicyBinding>,
    by_event: HashMap<String, Vec<usize>>,
    in_flight: HashSet<String>,
}

#[derive(Debug)]
pub struct PolicyTrigger {
    pub policy_name: String,
    pub command_name: String,
    pub event_data: HashMap<String, super::Value>,
    /// Resolved `with` literals (gap #1). Merged over `event_data` by
    /// `drain_policies` before `inject_refs` — the policy's explicit
    /// args win over an event field of the same name.
    pub with_data: HashMap<String, super::Value>,
    /// deciderate Layer 0b — carried from the binding so the caller (which
    /// has &Runtime) can sweep the query and fan out the primary trigger.
    pub for_each: Option<ForEachSpec>,
    /// deciderate Layer 0b — extra reactions the caller fires after the
    /// primary trigger (each with its own with-spec + optional sweep).
    pub extra_dispatches: Vec<DispatchSpec>,
}

impl PolicyEngine {
    pub fn new() -> Self {
        PolicyEngine {
            bindings: vec![],
            by_event: HashMap::new(),
            in_flight: HashSet::new(),
        }
    }

    pub fn register(
        &mut self,
        name: &str,
        on_event: &str,
        trigger_command: &str,
        with: Vec<(String, ValueSpec)>,
        wheres: Vec<WhereClause>,
        for_each: Option<ForEachSpec>,
        extra_dispatches: Vec<DispatchSpec>,
    ) {
        let idx = self.bindings.len();
        // gap #1b — split `Aggregate.Event` into (qualifier, event).
        // Bare `Event` → qualifier None. The index keys on the bare
        // event name either way ; the qualifier is checked in `react`.
        let (qualifier, event_name) = match on_event.split_once('.') {
            Some((agg, ev)) => (Some(agg.to_string()), ev.to_string()),
            None => (None, on_event.to_string()),
        };
        self.bindings.push(PolicyBinding {
            name: name.to_string(),
            on_event: on_event.to_string(),
            event_name: event_name.clone(),
            qualifier,
            trigger_command: trigger_command.to_string(),
            with,
            wheres,
            for_each,
            extra_dispatches,
        });
        self.by_event
            .entry(event_name)
            .or_default()
            .push(idx);
    }

    /// Check which policies should fire for this event.
    /// Returns commands to dispatch. Marks them in-flight.
    pub fn react(&mut self, event: &Event) -> Vec<PolicyTrigger> {
        let indices = match self.by_event.get(&event.name) {
            Some(v) => v.clone(),
            None => return vec![],
        };

        let mut triggers = vec![];
        for idx in indices {
            let binding = &self.bindings[idx];
            // gap #1b — an aggregate-qualified binding fires ONLY when
            // the firing event was emitted by that aggregate. A bare
            // binding (qualifier None) matches any emitter by name.
            if let Some(ref agg) = binding.qualifier {
                if agg != &event.aggregate_type {
                    continue;
                }
            }
            // deciderate Layer 0b — data guard. Build a transient state from
            // the event data ; require every clause to match (reuses the
            // canonical where_matches — no duplicate matcher).
            if !binding.wheres.is_empty() {
                let mut guard_state = super::AggregateState::new("");
                guard_state.fields = event.data.clone();
                let no_attrs: HashMap<String, String> = HashMap::new();
                if !binding
                    .wheres
                    .iter()
                    .all(|w| super::where_matches(&guard_state, w, &no_attrs))
                {
                    continue;
                }
            }
            if self.in_flight.contains(&binding.name) {
                continue;
            }
            self.in_flight.insert(binding.name.clone());
            // Resolve the `with` literals (gap #1). This slice only
            // produces `ValueSpec::Literal`, so resolution is direct ;
            // state-aware specs (FromState/templating) will route
            // through the runtime's evaluate_value_spec when added for
            // later families.
            let mut with_data: HashMap<String, super::Value> = HashMap::new();
            for (key, spec) in &binding.with {
                match spec {
                    ValueSpec::Literal { value } => {
                        with_data.insert(key.clone(), super::Value::Str(value.clone()));
                    }
                    // Cross-field rename (`map account: :destination`) : pull
                    // the named field off the TRIGGERING event, falling back to
                    // a declared default. This is what routes a cascade — the
                    // triggered command learns which aggregate to act on and
                    // carries the event's amount / provenance forward. Without
                    // it the rename is silently dropped and the cascade
                    // mis-routes to the upstream (the transfer-saga root bug).
                    ValueSpec::FromEvent { name, default } => {
                        if let Some(v) = event.data.get(name) {
                            with_data.insert(key.clone(), v.clone());
                        } else if let Some(d) = default {
                            with_data.insert(key.clone(), super::Value::Str(d.clone()));
                        }
                    }
                    _ => {}
                }
            }
            triggers.push(PolicyTrigger {
                policy_name: binding.name.clone(),
                command_name: binding.trigger_command.clone(),
                event_data: event.data.clone(),
                with_data,
                for_each: binding.for_each.clone(),
                extra_dispatches: binding.extra_dispatches.clone(),
            });
        }
        triggers
    }

    /// Clear in-flight marker after policy command completes
    pub fn complete(&mut self, policy_name: &str) {
        self.in_flight.remove(policy_name);
    }

    /// C3 cutover — clear ALL in-flight markers. Called after an outbox pump
    /// session drains to quiescence so the NEXT session starts with a fresh
    /// reentrancy guard. The guard breaks cyclic cascades WITHIN a session ;
    /// across sessions it must reset, or a long-running LoopDriver (one
    /// Runtime across many ticks) would skip every policy after tick 1.
    pub fn reset_in_flight(&mut self) {
        self.in_flight.clear();
    }

    pub fn bindings(&self) -> &[PolicyBinding] {
        &self.bindings
    }

    /// C1 (transactional outbox) — enumerate, WITHOUT firing, the policy
    /// trigger commands that WOULD react to an event. Read-only mirror of
    /// `react`'s selection logic (the qualifier match), minus the
    /// `in_flight` mutation. Used to PLAN a CascadeRun's steps for the
    /// persistent outbox before any reaction executes.
    pub fn trigger_commands_for(
        &self,
        event_name: &str,
        aggregate_type: &str,
    ) -> Vec<(String, Vec<(String, String)>)> {
        let indices = match self.by_event.get(event_name) {
            Some(v) => v,
            None => return vec![],
        };
        indices
            .iter()
            .filter_map(|&idx| {
                let b = &self.bindings[idx];
                if let Some(ref agg) = b.qualifier {
                    if agg != aggregate_type {
                        return None;
                    }
                }
                // `with` literals (static Literal specs only, mirroring react).
                let withs: Vec<(String, String)> = b
                    .with
                    .iter()
                    .filter_map(|(k, spec)| match spec {
                        ValueSpec::Literal { value } => Some((k.clone(), value.clone())),
                        _ => None,
                    })
                    .collect();
                Some((b.trigger_command.clone(), withs))
            })
            .collect()
    }
}
