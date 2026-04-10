//! PolicyEngine — reactive event→command wiring
//!
//! Policies subscribe to events and trigger follow-up commands.
//! Reentrant execution is prevented by tracking in-flight policies.
//!
//! Usage:
//!   engine.register("OnPizzaCreated", "PizzaCreated", "NotifyChef");
//!   let triggers = engine.react(&event);

use super::Event;
use std::collections::{HashMap, HashSet};

#[derive(Debug, Clone)]
pub struct PolicyBinding {
    pub name: String,
    pub on_event: String,
    pub trigger_command: String,
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
}

impl PolicyEngine {
    pub fn new() -> Self {
        PolicyEngine {
            bindings: vec![],
            by_event: HashMap::new(),
            in_flight: HashSet::new(),
        }
    }

    pub fn register(&mut self, name: &str, on_event: &str, trigger_command: &str) {
        let idx = self.bindings.len();
        self.bindings.push(PolicyBinding {
            name: name.to_string(),
            on_event: on_event.to_string(),
            trigger_command: trigger_command.to_string(),
        });
        self.by_event
            .entry(on_event.to_string())
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
            if self.in_flight.contains(&binding.name) {
                continue;
            }
            self.in_flight.insert(binding.name.clone());
            triggers.push(PolicyTrigger {
                policy_name: binding.name.clone(),
                command_name: binding.trigger_command.clone(),
                event_data: event.data.clone(),
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
}
