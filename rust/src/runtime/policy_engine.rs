//! PolicyEngine — reactive event→command wiring
//!
//! Policies subscribe to events and trigger follow-up commands.
//! Reentrant execution is prevented by tracking in-flight policies.
//!
//! Usage:
//!   engine.register("OnPizzaCreated", "PizzaCreated", "NotifyChef");
//!   let triggers = engine.react(&event);

use super::Event;
use crate::ir::ValueSpec;
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
                if let ValueSpec::Literal { value } = spec {
                    with_data.insert(key.clone(), super::Value::Str(value.clone()));
                }
            }
            triggers.push(PolicyTrigger {
                policy_name: binding.name.clone(),
                command_name: binding.trigger_command.clone(),
                event_data: event.data.clone(),
                with_data,
            });
        }
        triggers
    }

    /// Clear in-flight marker after policy command completes
    pub fn complete(&mut self, policy_name: &str) {
        self.in_flight.remove(policy_name);
    }

    pub fn bindings(&self) -> &[PolicyBinding] {
        &self.bindings
    }

    /// C1 (transactional outbox) — enumerate, WITHOUT firing, the policy
    /// trigger commands that WOULD react to an event. Read-only mirror of
    /// `react`'s selection logic (the qualifier match), minus the
    /// `in_flight` mutation. Used to PLAN a CascadeRun's steps for the
    /// persistent outbox before any reaction executes.
    pub fn trigger_commands_for(&self, event_name: &str, aggregate_type: &str) -> Vec<String> {
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
                Some(b.trigger_command.clone())
            })
            .collect()
    }
}
