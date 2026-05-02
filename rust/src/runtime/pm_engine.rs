//! PMEngine — process_manager runtime execution
//!
//! Stateful coordinator for `process_manager` declarations. Each
//! `ProcessManager` IR registers its handlers ; on each event published
//! to the bus, PMEngine looks up bindings, finds matching PM instances
//! by correlation_id, transitions state per from/to map, and returns
//! commands to dispatch via the handler's declared `dispatch` list.
//!
//! Mirrors `PolicyEngine` shape — both react to events ; PMEngine adds
//! per-correlation state.
//!
//! Two layers of bluebook-first :
//!   - L_a (this file) : PMs are bluebook ; this generic interpreter
//!     drives them. Kernel floor at this layer.
//!   - L_b (follow-on `runtime_engine` branch) : the engine itself
//!     declared as bluebook ; one interpreter walks all engine kinds
//!     (Policy + PM + Workflow). Future work.

use super::Event;
use crate::ir::{ProcessManager, ProcessManagerHandler};
use std::collections::{HashMap, HashSet};

#[derive(Debug, Clone)]
pub struct PMBinding {
    pub name: String,
    pub correlates_by: String,
    pub starts_on: String,
    pub ends_on: Option<String>,
    pub states: Vec<String>,
    pub handlers: Vec<ProcessManagerHandler>,
    pub instances: HashMap<String, PMInstanceState>,
}

#[derive(Debug, Clone)]
pub struct PMInstanceState {
    pub correlation_id: String,
    pub state: String,
    pub last_event: Option<String>,
}

/// What PMEngine returns when an event triggers state changes.
/// `dispatches` carries the "Aggregate.Command" strings declared
/// via the handler's `dispatch "..."` lines ; caller dispatches them.
#[derive(Debug, Clone)]
pub struct PMTrigger {
    pub pm_name: String,
    pub correlation_id: String,
    pub from_state: String,
    pub to_state: String,
    pub event_name: String,
    pub dispatches: Vec<String>,
}

pub struct PMEngine {
    bindings: HashMap<String, PMBinding>,
    in_flight: HashSet<String>,
}

impl PMEngine {
    pub fn new() -> Self {
        PMEngine {
            bindings: HashMap::new(),
            in_flight: HashSet::new(),
        }
    }

    pub fn register(&mut self, pm_ir: &ProcessManager) {
        let existing_instances = self
            .bindings
            .get(&pm_ir.name)
            .map(|b| b.instances.clone())
            .unwrap_or_default();
        self.bindings.insert(
            pm_ir.name.clone(),
            PMBinding {
                name: pm_ir.name.clone(),
                correlates_by: pm_ir.correlates_by.clone(),
                starts_on: pm_ir.starts_on.clone(),
                ends_on: pm_ir.ends_on.clone(),
                states: pm_ir.states.clone(),
                handlers: pm_ir.handlers.clone(),
                instances: existing_instances,
            },
        );
    }

    pub fn react(&mut self, event: &Event) -> Vec<PMTrigger> {
        let mut triggers = vec![];
        let names: Vec<String> = self.bindings.keys().cloned().collect();
        for pm_name in names {
            if self.in_flight.contains(&pm_name) {
                continue;
            }
            if let Some(t) = self.try_react_one(&pm_name, event) {
                self.in_flight.insert(pm_name.clone());
                triggers.push(t);
            }
        }
        triggers
    }

    fn try_react_one(&mut self, pm_name: &str, event: &Event) -> Option<PMTrigger> {
        let binding = self.bindings.get_mut(pm_name)?;
        let correlation_id = extract_correlation_id(event, &binding.correlates_by)?;

        // Get-or-create-on-starts_on : starts_on creates fresh instance
        // in first declared state ; other events for non-existent
        // instances are ignored.
        let current_state = match binding.instances.get(&correlation_id) {
            Some(inst) => inst.state.clone(),
            None => {
                if event.name == binding.starts_on {
                    let initial = binding.states.first().cloned().unwrap_or_default();
                    binding.instances.insert(
                        correlation_id.clone(),
                        PMInstanceState {
                            correlation_id: correlation_id.clone(),
                            state: initial.clone(),
                            last_event: Some(event.name.clone()),
                        },
                    );
                    initial
                } else {
                    return None;
                }
            }
        };

        let handler = binding
            .handlers
            .iter()
            .find(|h| h.event_type == event.name && h.from_state == current_state)?;
        let from_state = handler.from_state.clone();
        let to_state = handler.to_state.clone();
        let dispatches = handler.dispatches.clone();

        binding.instances.insert(
            correlation_id.clone(),
            PMInstanceState {
                correlation_id: correlation_id.clone(),
                state: to_state.clone(),
                last_event: Some(event.name.clone()),
            },
        );

        Some(PMTrigger {
            pm_name: pm_name.to_string(),
            correlation_id,
            from_state,
            to_state,
            event_name: event.name.clone(),
            dispatches,
        })
    }

    pub fn complete(&mut self, pm_name: &str) {
        self.in_flight.remove(pm_name);
    }

    pub fn bindings(&self) -> impl Iterator<Item = &PMBinding> {
        self.bindings.values()
    }

    pub fn instances(&self, pm_name: &str) -> Option<&HashMap<String, PMInstanceState>> {
        self.bindings.get(pm_name).map(|b| &b.instances)
    }
}

fn extract_correlation_id(event: &Event, correlates_by: &str) -> Option<String> {
    if let Some(v) = event.data.get(correlates_by) {
        return Some(v.to_string());
    }
    Some(event.aggregate_id.clone())
}

impl Default for PMEngine {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ir::{ProcessManager, ProcessManagerHandler};
    use crate::runtime::Value;
    use std::collections::HashMap;

    fn order_pm() -> ProcessManager {
        ProcessManager {
            name: "OrderFulfillment".to_string(),
            correlates_by: "order_id".to_string(),
            starts_on: "OrderPlaced".to_string(),
            ends_on: Some("OrderDelivered".to_string()),
            states: vec!["pending".into(), "shipped".into(), "delivered".into()],
            handlers: vec![
                ProcessManagerHandler {
                    event_type: "OrderShipped".into(),
                    from_state: "pending".into(),
                    to_state: "shipped".into(),
                    dispatches: vec!["Inventory.Decrement".into()],
                },
                ProcessManagerHandler {
                    event_type: "OrderDelivered".into(),
                    from_state: "shipped".into(),
                    to_state: "delivered".into(),
                    dispatches: vec![],
                },
            ],
        }
    }

    fn evt(name: &str, order_id: &str) -> Event {
        let mut data = HashMap::new();
        data.insert("order_id".into(), Value::Str(order_id.into()));
        Event {
            name: name.into(),
            aggregate_type: "Order".into(),
            aggregate_id: order_id.into(),
            data,
        }
    }

    #[test]
    fn full_lifecycle() {
        let mut engine = PMEngine::new();
        engine.register(&order_pm());

        let _ = engine.react(&evt("OrderPlaced", "ord_42"));
        engine.complete("OrderFulfillment");

        let triggers = engine.react(&evt("OrderShipped", "ord_42"));
        assert_eq!(triggers.len(), 1);
        assert_eq!(triggers[0].from_state, "pending");
        assert_eq!(triggers[0].to_state, "shipped");
        assert_eq!(triggers[0].dispatches, vec!["Inventory.Decrement".to_string()]);

        engine.complete("OrderFulfillment");
        let triggers = engine.react(&evt("OrderDelivered", "ord_42"));
        assert_eq!(triggers.len(), 1);
        assert_eq!(triggers[0].to_state, "delivered");
        assert_eq!(triggers[0].dispatches, Vec::<String>::new());
    }

    #[test]
    fn no_op_for_unrelated_event() {
        let mut engine = PMEngine::new();
        engine.register(&order_pm());
        assert_eq!(engine.react(&evt("RandomEvent", "ord_42")).len(), 0);
    }

    #[test]
    fn isolated_correlation_ids() {
        let mut engine = PMEngine::new();
        engine.register(&order_pm());
        let _ = engine.react(&evt("OrderPlaced", "ord_1"));
        engine.complete("OrderFulfillment");
        let _ = engine.react(&evt("OrderPlaced", "ord_2"));
        engine.complete("OrderFulfillment");
        let instances = engine.instances("OrderFulfillment").unwrap();
        assert_eq!(instances.len(), 2);
    }
}
