//! PMEngine — process_manager runtime execution
//!
//! [antibody-exempt: rust/src/runtime/pm_engine.rs — generic state-machine
//!  interpreter for process_manager IR. PMs are bluebook ; this Rust
//!  runtime that drives them is kernel floor at L_a (mirror of
//!  policy_engine.rs). The deeper L_b lift — `runtime_engine` primitive
//!  unifying PolicyEngine + PMEngine + WorkflowExecutor as one
//!  declarable kind — is filed as a follow-on branch (see
//!  miette/dream-study/DEBRIEF.md → "Bluebook-First backlog").]
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
use crate::heki;
use crate::ir::{DispatchSpec, ProcessManager, ProcessManagerHandler};
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
    /// Per-instance attribute storage. Phase 2.c
    /// (pm-attribute-writes) — writes flow in from `set :attr, ...`
    /// directives in PM handlers ; reads flow out via `from_pm(:attr)`
    /// in the same handlers' dispatch with-specs. Stringly typed to
    /// match the existing ValueSpec literal/default convention ; the
    /// dispatch evaluator wraps reads as `Value::Str`.
    pub attributes: HashMap<String, String>,
}

/// What PMEngine returns when an event triggers state changes.
/// `dispatches` carries the structured DispatchSpec entries declared
/// via the handler's `dispatch "Cmd", with: { ... }` lines ; caller
/// evaluates each spec's with_spec at dispatch time and routes
/// through the cascade dispatcher.
#[derive(Debug, Clone)]
pub struct PMTrigger {
    pub pm_name: String,
    pub correlation_id: String,
    pub from_state: String,
    pub to_state: String,
    pub event_name: String,
    pub dispatches: Vec<DispatchSpec>,
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
                            attributes: HashMap::new(),
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

        // Preserve per-instance attributes across the transition. Set
        // directives evaluated by the runtime later (drain_pms) mutate
        // them in place via `apply_set` ; this clone keeps anything
        // that was set on a previous handler firing intact when the
        // current handler doesn't write to that key.
        let prior_attributes = binding
            .instances
            .get(&correlation_id)
            .map(|inst| inst.attributes.clone())
            .unwrap_or_default();

        binding.instances.insert(
            correlation_id.clone(),
            PMInstanceState {
                correlation_id: correlation_id.clone(),
                state: to_state.clone(),
                last_event: Some(event.name.clone()),
                attributes: prior_attributes,
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

    /// Phase 2.c — apply one resolved (attr, value) pair to the named
    /// PM instance's per-instance attribute map. Caller (Runtime
    /// drain_pms) evaluates the handler's `set_specs` ValueSpecs first
    /// (using the same evaluator as `with_spec`), then walks the
    /// resolved pairs through `apply_set`. No-op when the binding or
    /// instance is missing — drain_pms only reaches this after a
    /// successful PMTrigger so the row exists in normal flow.
    pub fn apply_set(&mut self, pm_name: &str, correlation_id: &str, attr: &str, value: String) {
        if let Some(binding) = self.bindings.get_mut(pm_name) {
            if let Some(inst) = binding.instances.get_mut(correlation_id) {
                inst.attributes.insert(attr.to_string(), value);
            }
        }
    }

    /// Phase 2.c — read one attribute off a PM instance for
    /// from_pm(:attr) evaluation. Returns None when the binding,
    /// instance, or attribute is absent ; the caller falls back to
    /// the ValueSpec's `default`.
    pub fn read_attribute(&self, pm_name: &str, correlation_id: &str, attr: &str) -> Option<&str> {
        self.bindings
            .get(pm_name)
            .and_then(|b| b.instances.get(correlation_id))
            .and_then(|inst| inst.attributes.get(attr).map(|s| s.as_str()))
    }

    pub fn bindings(&self) -> impl Iterator<Item = &PMBinding> {
        self.bindings.values()
    }

    pub fn instances(&self, pm_name: &str) -> Option<&HashMap<String, PMInstanceState>> {
        self.bindings.get(pm_name).map(|b| &b.instances)
    }

    // ---- Phase D : heki persistence -----------------------------------
    //
    // Production daemons fork storehouse per dispatch. Without persistence,
    // each subprocess builds an empty PMEngine and transitions don't
    // accumulate across ticks. Persistence routes each PM's instances
    // through `<data_dir>/process_managers/<pm_snake>.heki`. Records are
    // keyed by correlation_id ; each record carries state + last_event.
    // Last-write-wins on race ; the daemon model dispatches one event
    // per fork so concurrent writes to the same instance are rare.

    /// Load existing PM instances from heki for every registered PM.
    /// Called once at Runtime boot after register. No-op when data_dir
    /// is None (in-memory test runtimes don't persist).
    pub fn load_persisted(&mut self, data_dir: Option<&str>) {
        let dir = match data_dir {
            Some(d) => d,
            None => return,
        };
        let names: Vec<String> = self.bindings.keys().cloned().collect();
        for pm_name in names {
            let path = pm_heki_path(dir, &pm_name);
            let store = match heki::read(&path) {
                Ok(s) => s,
                Err(_) => continue,
            };
            if let Some(binding) = self.bindings.get_mut(&pm_name) {
                for (correlation_id, record) in store {
                    let state = record
                        .get("state")
                        .and_then(|v| v.as_str())
                        .unwrap_or("")
                        .to_string();
                    let last_event = record
                        .get("last_event")
                        .and_then(|v| v.as_str())
                        .map(String::from);
                    // Phase 2.c — read the per-instance attributes hash
                    // back. The on-disk shape is a JSON object under
                    // the "attributes" key ; missing key (legacy
                    // pre-2.c records) loads as an empty hash.
                    let attributes = record
                        .get("attributes")
                        .and_then(|v| v.as_object())
                        .map(|obj| {
                            obj.iter()
                                .filter_map(|(k, v)| {
                                    v.as_str().map(|s| (k.clone(), s.to_string()))
                                })
                                .collect::<HashMap<String, String>>()
                        })
                        .unwrap_or_default();
                    binding.instances.insert(
                        correlation_id.clone(),
                        PMInstanceState {
                            correlation_id,
                            state,
                            last_event,
                            attributes,
                        },
                    );
                }
            }
        }
    }

    /// Persist one instance's current state to heki. Called by Runtime
    /// after each successful react. Idempotent — re-persisting the
    /// same state is a no-op heki-side besides bumping updated_at.
    pub fn persist_instance(
        &self,
        pm_name: &str,
        correlation_id: &str,
        data_dir: Option<&str>,
    ) -> Result<(), String> {
        let dir = match data_dir {
            Some(d) => d,
            None => return Ok(()),
        };
        let binding = self
            .bindings
            .get(pm_name)
            .ok_or_else(|| format!("pm_engine.persist : no binding for {}", pm_name))?;
        let inst = binding
            .instances
            .get(correlation_id)
            .ok_or_else(|| format!("pm_engine.persist : no instance for {}/{}", pm_name, correlation_id))?;

        let mut record: heki::Record = HashMap::new();
        record.insert(
            "id".to_string(),
            serde_json::Value::String(correlation_id.to_string()),
        );
        record.insert(
            "state".to_string(),
            serde_json::Value::String(inst.state.clone()),
        );
        if let Some(le) = &inst.last_event {
            record.insert(
                "last_event".to_string(),
                serde_json::Value::String(le.clone()),
            );
        }
        // Phase 2.c — round-trip per-instance attributes. Always
        // emitted (even when empty) so loaders see a consistent shape ;
        // empty hash deserialises identically to the missing-key case
        // for legacy records.
        let mut attrs_obj = serde_json::Map::new();
        for (k, v) in &inst.attributes {
            attrs_obj.insert(k.clone(), serde_json::Value::String(v.clone()));
        }
        record.insert(
            "attributes".to_string(),
            serde_json::Value::Object(attrs_obj),
        );

        let path = pm_heki_path(dir, pm_name);
        // Ensure the parent dir exists before heki tries to write.
        if let Some(parent) = std::path::Path::new(&path).parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        heki::upsert(
            &path,
            &record,
            heki::WriteContext::Dispatch {
                aggregate: pm_name,
                command: "PMTransition",
            },
        )?;
        Ok(())
    }
}

/// Heki path for a process manager's instance store.
/// Convention : `<data_dir>/process_managers/<pm_snake>.heki`
fn pm_heki_path(data_dir: &str, pm_name: &str) -> String {
    let snake = heki::snake_case(pm_name);
    let trimmed = data_dir.trim_end_matches('/');
    format!("{}/process_managers/{}.heki", trimmed, snake)
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
                    dispatches: vec![DispatchSpec {
                        command_name: "Inventory.Decrement".into(),
                        with_spec: vec![],
                        for_each: None,
                    }],
                    set_specs: vec![],
                },
                ProcessManagerHandler {
                    event_type: "OrderDelivered".into(),
                    from_state: "shipped".into(),
                    to_state: "delivered".into(),
                    dispatches: vec![],
                    set_specs: vec![],
                }, // dispatches: empty Vec<DispatchSpec>
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
        assert_eq!(triggers[0].dispatches.len(), 1);
        assert_eq!(triggers[0].dispatches[0].command_name, "Inventory.Decrement");
        assert!(triggers[0].dispatches[0].with_spec.is_empty());

        engine.complete("OrderFulfillment");
        let triggers = engine.react(&evt("OrderDelivered", "ord_42"));
        assert_eq!(triggers.len(), 1);
        assert_eq!(triggers[0].to_state, "delivered");
        assert!(triggers[0].dispatches.is_empty());
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

    #[test]
    fn persists_and_reloads_instance_state() {
        let tmp = std::env::temp_dir().join(format!(
            "hecks_pm_persist_test_{}",
            crate::heki::now_duration()
                .as_nanos()
        ));
        let dir = tmp.to_string_lossy().to_string();
        std::fs::create_dir_all(&dir).unwrap();

        // Subprocess 1 : create instance, transition, persist.
        {
            let mut engine = PMEngine::new();
            engine.register(&order_pm());
            engine.load_persisted(Some(&dir));

            let _ = engine.react(&evt("OrderPlaced", "ord_42"));
            engine.complete("OrderFulfillment");
            engine
                .persist_instance("OrderFulfillment", "ord_42", Some(&dir))
                .unwrap();

            let _ = engine.react(&evt("OrderShipped", "ord_42"));
            engine
                .persist_instance("OrderFulfillment", "ord_42", Some(&dir))
                .unwrap();
            engine.complete("OrderFulfillment");
        }

        // Subprocess 2 : load + verify the prior state persisted.
        {
            let mut engine = PMEngine::new();
            engine.register(&order_pm());
            engine.load_persisted(Some(&dir));

            let instances = engine.instances("OrderFulfillment").unwrap();
            let inst = instances.get("ord_42").expect("instance must be loaded");
            assert_eq!(inst.state, "shipped", "state should persist across forks");
            assert_eq!(inst.last_event.as_deref(), Some("OrderShipped"));

            // And further transitions on top of loaded state work :
            let triggers = engine.react(&evt("OrderDelivered", "ord_42"));
            assert_eq!(triggers.len(), 1);
            assert_eq!(triggers[0].from_state, "shipped");
            assert_eq!(triggers[0].to_state, "delivered");
        }

        let _ = std::fs::remove_dir_all(&tmp);
    }

    // ---- Phase 2.c — PM attribute writes -----------------------------

    #[test]
    fn apply_set_writes_per_instance_attribute() {
        let mut engine = PMEngine::new();
        engine.register(&order_pm());
        let _ = engine.react(&evt("OrderPlaced", "ord_42"));
        engine.complete("OrderFulfillment");

        engine.apply_set("OrderFulfillment", "ord_42", "carrying", "body".into());
        assert_eq!(
            engine.read_attribute("OrderFulfillment", "ord_42", "carrying"),
            Some("body")
        );
    }

    #[test]
    fn read_attribute_returns_none_when_unset() {
        let mut engine = PMEngine::new();
        engine.register(&order_pm());
        let _ = engine.react(&evt("OrderPlaced", "ord_42"));
        engine.complete("OrderFulfillment");

        assert!(engine.read_attribute("OrderFulfillment", "ord_42", "missing").is_none());
        assert!(engine.read_attribute("OrderFulfillment", "missing_id", "x").is_none());
        assert!(engine.read_attribute("Missing", "ord_42", "x").is_none());
    }

    #[test]
    fn attributes_survive_subsequent_transitions() {
        let mut engine = PMEngine::new();
        engine.register(&order_pm());
        let _ = engine.react(&evt("OrderPlaced", "ord_42"));
        engine.complete("OrderFulfillment");
        engine.apply_set("OrderFulfillment", "ord_42", "carrying", "body".into());

        // Drive the next transition ; attribute must still be there.
        let _ = engine.react(&evt("OrderShipped", "ord_42"));
        engine.complete("OrderFulfillment");
        assert_eq!(
            engine.read_attribute("OrderFulfillment", "ord_42", "carrying"),
            Some("body")
        );
    }

    #[test]
    fn attributes_round_trip_through_heki_persistence() {
        let tmp = std::env::temp_dir().join(format!(
            "hecks_pm_attrs_test_{}",
            crate::heki::now_duration()
                .as_nanos()
        ));
        let dir = tmp.to_string_lossy().to_string();
        std::fs::create_dir_all(&dir).unwrap();

        // Subprocess 1 : create, set attr, persist.
        {
            let mut engine = PMEngine::new();
            engine.register(&order_pm());
            engine.load_persisted(Some(&dir));
            let _ = engine.react(&evt("OrderPlaced", "ord_42"));
            engine.complete("OrderFulfillment");
            engine.apply_set("OrderFulfillment", "ord_42", "carrying", "body".into());
            engine.apply_set("OrderFulfillment", "ord_42", "tick", "7".into());
            engine
                .persist_instance("OrderFulfillment", "ord_42", Some(&dir))
                .unwrap();
        }

        // Subprocess 2 : load + verify the attributes persisted.
        {
            let mut engine = PMEngine::new();
            engine.register(&order_pm());
            engine.load_persisted(Some(&dir));
            assert_eq!(
                engine.read_attribute("OrderFulfillment", "ord_42", "carrying"),
                Some("body")
            );
            assert_eq!(
                engine.read_attribute("OrderFulfillment", "ord_42", "tick"),
                Some("7")
            );
        }

        let _ = std::fs::remove_dir_all(&tmp);
    }
}
