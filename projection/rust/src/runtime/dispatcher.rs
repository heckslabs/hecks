//! dispatcher - the door, in Rust.
//!
//! The same six steps the Ruby dispatcher runs, in the same order, driven by
//! the same IR:
//!
//!   1. resolve   verb -> bluebook -> aggregate -> command
//!   2. hydrate   load by id, or mint a fresh instance for a creating command
//!   3. guard     every given must hold, or the command is refused untouched
//!   4. mutate    creation attributes, then each then_set
//!   5. persist   store the instance
//!   6. emit      announce, only after the state is stored
//!
//! There is no handler body here either. This file knows nothing about pizzas -
//! it knows how to read an IR. That is what makes it a runtime rather than an
//! implementation.

use crate::heki::WriteContext;
use crate::interp_expr::State;
use crate::interp_givens::evaluate_given;
use crate::interp_mutations::{apply_mutation, assign_creation_attributes, defaults_for};
use crate::runtime::PersistenceAdapter;
use crate::value_bridge;
use serde_json::{json, Map, Value};
use std::collections::BTreeMap;

pub struct Runtime {
    ir: Value,
    /// Used only when NO persistence adapter is attached. When one is, the
    /// adapter is the store - a cache alongside it would let the runtime
    /// appear to work while the adapter silently did nothing.
    store: BTreeMap<String, State>,
    /// One adapter per aggregate, keyed by aggregate name.
    ///
    /// The PORT, never a concrete type. This library must not know that SQLite
    /// exists - the adapter depends on the port, and Cargo enforces it as a
    /// dependency cycle if you get it backwards. cli/ is where the two are
    /// named together.
    adapters: BTreeMap<String, Box<dyn PersistenceAdapter>>,
    pub events: Vec<Value>,
    /// Every policy that FIRED, and whether its command was delivered. The
    /// projection of Ruby's `registry.reaction_log`. A reaction nobody records
    /// is a reaction nobody misses — which is how four declared policies ran
    /// nowhere in BOTH runtimes while parity stayed green.
    pub reactions: Vec<Value>,
    minted: usize,
    /// How deep the current reaction chain is. A policy whose command emits the
    /// event it waits for would react for ever ; bounded rather than detected,
    /// because the cycle is a modelling error and the runtime's job is to stop
    /// rather than to diagnose.
    reaction_depth: usize,
}

/// Mirrors Ruby's MAX_REACTION_DEPTH.
const MAX_REACTION_DEPTH: usize = 5;

impl Runtime {
    pub fn new(ir: Value) -> Self {
        Runtime {
            ir,
            store: BTreeMap::new(),
            adapters: BTreeMap::new(),
            events: Vec::new(),
            reactions: Vec::new(),
            minted: 0,
            reaction_depth: 0,
        }
    }

    /// Attach the adapter the hecksagon bound, for one aggregate.
    pub fn attach(&mut self, aggregate: &str, adapter: Box<dyn PersistenceAdapter>) {
        self.adapters.insert(aggregate.to_string(), adapter);
    }

    /// Every aggregate the loaded IR declares, as (name, declaration).
    pub fn aggregates(&self) -> Vec<(String, Map<String, Value>)> {
        let mut found = vec![];
        for domain in self.ir.as_object().cloned().unwrap_or_default().values() {
            for aggregate in domain.get("aggregates").and_then(Value::as_array).cloned().unwrap_or_default() {
                if let Some(object) = aggregate.as_object() {
                    let name = object.get("name").and_then(Value::as_str).unwrap_or_default();
                    found.push((name.to_string(), object.clone()));
                }
            }
        }
        found
    }

    /// What the STORE holds, keyed Domain::Aggregate#id. When an adapter is
    /// bound the answer comes from the adapter, so this reports what was really
    /// written rather than what the runtime believes it wrote.
    pub fn instances(&self) -> BTreeMap<String, State> {
        if self.adapters.is_empty() {
            return self.store.clone();
        }

        let mut found = BTreeMap::new();
        for (domain_name, domain) in self.ir.as_object().cloned().unwrap_or_default() {
            for aggregate in domain.get("aggregates").and_then(Value::as_array).cloned().unwrap_or_default() {
                let Some(aggregate) = aggregate.as_object() else { continue };
                let name = aggregate.get("name").and_then(Value::as_str).unwrap_or_default();

                let Some(adapter) = self.adapters.get(name) else { continue };
                for state in adapter.all() {
                    found.insert(
                        format!("{}::{}#{}", domain_name, name, state.id),
                        value_bridge::from_state(state),
                    );
                }
            }
        }
        found
    }

    pub fn dispatch(&mut self, verb: &str, args: &State) -> Result<State, String> {
        let (domain, aggregate_name, command_name) = parse_verb(verb)?;
        let aggregate = self.find_aggregate(&domain, &aggregate_name, verb)?;
        let command = find_command(&aggregate, &command_name)
            .ok_or_else(|| format!("{} has no command {:?}", aggregate_name, command_name))?;

        let identity = aggregate
            .get("identified_by")
            .and_then(Value::as_str)
            .unwrap_or("id")
            .to_string();
        let creates = command.get("references").map(Value::is_null).unwrap_or(true);

        let (id, mut state) = self.hydrate(&aggregate, &command, args, &identity, creates)?;

        // Guard before anything is written, so a refused command leaves no trace.
        for given in array(&command, "givens") {
            let canonical = given.get("canonical").and_then(Value::as_str).unwrap_or("");
            if !evaluate_given(canonical, &state, args)? {
                let description = given.get("description").and_then(Value::as_str).unwrap_or("");
                return Err(format!("{} refused — {}", command_name, description));
            }
        }

        if creates {
            assign_creation_attributes(&mut state, &aggregate, &command, args)?;
        }
        for mutation in array(&command, "mutations") {
            apply_mutation(&mut state, &aggregate, &mutation, args)?;
        }

        // PERSIST through the adapter the hecksagon bound.
        match self.adapters.get_mut(&aggregate_name) {
            Some(adapter) => adapter.save(
                value_bridge::to_state(&id, &state),
                WriteContext::Dispatch { aggregate: &aggregate_name, command: &command_name },
            ),
            None => {
                let key = format!("{}::{}#{}", domain, aggregate_name, id);
                self.store.insert(key, state.clone());
            }
        }

        // Emitting last: an event is a promise that the state behind it survived.
        let mut announced: Vec<Value> = Vec::new();
        for emitted in array(&command, "emits") {
            if let Some(name) = emitted.as_str() {
                let event = json!({
                    "name": name,
                    "aggregate": format!("{}::{}", domain, aggregate_name),
                    "id": id,
                    "payload": Value::Object(args.clone()),
                });

                // Events live in the runtime log, not in the persistence port.
                // Hecks keeps them in event_log.rs, which is a separate concern
                // and not part of PersistenceAdapter - an adapter stores
                // aggregates. Both runtimes report this log, so the harness
                // still compares every emission.
                self.events.push(event.clone());
                announced.push(event);
            }
        }

        // REACT - a policy is a standing instruction that something else should
        // follow, so the reflex fires after the event it waits for. After emit,
        // for the same reason emit is last: a reaction is a promise the state
        // behind it survived.
        for event in &announced {
            self.react_to(event, &domain);
        }

        let mut result = state;
        result.insert(identity, Value::String(id));
        Ok(result)
    }

    fn hydrate(
        &mut self,
        aggregate: &Map<String, Value>,
        command: &Map<String, Value>,
        args: &State,
        identity: &str,
        creates: bool,
    ) -> Result<(String, State), String> {
        let aggregate_name = aggregate.get("name").and_then(Value::as_str).unwrap_or("").to_string();
        let command_name = command.get("name").and_then(Value::as_str).unwrap_or("command");

        if creates {
            let id = args
                .get(identity)
                .and_then(Value::as_str)
                .map(str::to_string)
                .unwrap_or_else(|| {
                    self.minted += 1;
                    format!("{}-{}", storage_name(&aggregate_name), self.minted)
                });
            return Ok((id, defaults_for(aggregate)));
        }

        let id = args
            .get(identity)
            .and_then(Value::as_str)
            .ok_or_else(|| format!("{} acts on an existing {} — pass {}:", command_name, aggregate_name, identity))?
            .to_string();

        // The bound adapter is the store. Reading from a cache instead would
        // let the adapter be silently broken while everything looked fine.
        if let Some(adapter) = self.adapters.get(&aggregate_name) {
            let state = adapter
                .find(&id)
                .map(value_bridge::from_state)
                .ok_or_else(|| format!("no {} with {} {:?}", aggregate_name, identity, id))?;
            return Ok((id, state));
        }

        let key = self
            .store
            .keys()
            .find(|key| key.ends_with(&format!("::{}#{}", aggregate_name, id)))
            .cloned()
            .ok_or_else(|| format!("no {} with {} {:?}", aggregate_name, identity, id))?;

        Ok((id, self.store[&key].clone()))
    }

    /// The domain's reflex. The projection of Ruby's `react_to` in
    /// lib/hecksagain/runtime/dispatcher.rb, which holds the semantics.
    ///
    /// EVERY reaction is recorded, delivered or not. A policy pointing at a
    /// domain nobody loaded (pizzas' Notifications.Send) is a real thing to know
    /// about, and swallowing it would rebuild the silence this fixes.
    fn react_to(&mut self, event: &Value, domain: &str) {
        // Matches are collected as OWNED data before dispatching : the nested
        // dispatch takes `&mut self`, so a borrow of `self.ir` cannot still be
        // live when it runs.
        let matched = self.policies_for(event, domain);

        for (name, target) in matched {
            let mut record = json!({
                "policy": name,
                "on": event.get("name").cloned().unwrap_or(Value::Null),
                "trigger": target,
            });

            let outcome = if self.reaction_depth >= MAX_REACTION_DEPTH {
                Err(format!("reaction depth {MAX_REACTION_DEPTH} reached"))
            } else {
                let payload = event
                    .get("payload")
                    .and_then(Value::as_object)
                    .cloned()
                    .unwrap_or_default();

                self.reaction_depth += 1;
                let result = self.dispatch(&target, &payload);
                self.reaction_depth -= 1;
                result.map(|_| ())
            };

            let entry = record.as_object_mut().expect("record is an object");
            match outcome {
                Ok(()) => {
                    entry.insert("delivered".into(), Value::Bool(true));
                }
                // Recorded rather than propagated. The triggering command already
                // succeeded and its state is saved ; a consequence that cannot be
                // delivered does not retract it. What it must not do is vanish.
                Err(reason) => {
                    entry.insert("delivered".into(), Value::Bool(false));
                    entry.insert("reason".into(), Value::String(reason));
                }
            }

            self.reactions.push(record);
        }
    }

    /// The policies watching for this event, as (policy name, target verb).
    ///
    /// DOMAIN-LEVEL ONLY. An aggregate-nested policy BUBBLES to the domain at
    /// build time and the aggregate keeps a copy for its own IR ; reading both
    /// lists fires every nested policy twice.
    ///
    /// A policy matches on the event NAME, and when its subscription is
    /// qualified (`on "Order.Placed"`) on the emitting aggregate too.
    fn policies_for(&self, event: &Value, domain: &str) -> Vec<(String, String)> {
        let Some(name) = event.get("name").and_then(Value::as_str) else {
            return Vec::new();
        };
        let emitting = event
            .get("aggregate")
            .and_then(Value::as_str)
            .and_then(|fqn| fqn.rsplit("::").next())
            .unwrap_or_default();

        let Some(policies) = self
            .ir
            .get(domain)
            .and_then(|bluebook| bluebook.get("policies"))
            .and_then(Value::as_array)
        else {
            return Vec::new();
        };

        policies
            .iter()
            .filter_map(|policy| {
                let on_event = policy.get("on_event").and_then(Value::as_str)?;
                let (qualifier, event_name) = match on_event.split_once('.') {
                    Some((aggregate, bare)) => (Some(aggregate), bare),
                    None => (None, on_event),
                };

                if event_name != name {
                    return None;
                }
                if qualifier.is_some_and(|aggregate| aggregate != emitting) {
                    return None;
                }

                let trigger = policy.get("trigger_command").and_then(Value::as_str)?;
                let target_domain = policy
                    .get("target_domain")
                    .and_then(Value::as_str)
                    .unwrap_or(domain);

                Some((
                    policy.get("name").and_then(Value::as_str).unwrap_or_default().to_string(),
                    format!("{target_domain}::{trigger}"),
                ))
            })
            .collect()
    }

    /// The verb rides along ONLY for the not-found message. Ruby says "no domain
    /// X loaded (verb ...)" and this said "no domain X in the IR" — the same
    /// failure phrased two ways, unnoticed because the only refusals the corpus
    /// exercised were GivenNotMet. Adding reactions to the parity contract is
    /// what surfaced it : a policy pointing at an unloaded domain fails here, and
    /// its reason is compared.
    fn find_aggregate(&self, domain: &str, name: &str, verb: &str) -> Result<Map<String, Value>, String> {
        let bluebook = self
            .ir
            .get(domain)
            .ok_or_else(|| format!("no domain {domain:?} loaded (verb {verb})"))?;

        bluebook
            .get("aggregates")
            .and_then(Value::as_array)
            .and_then(|aggregates| {
                aggregates
                    .iter()
                    .find(|a| a.get("name").and_then(Value::as_str) == Some(name))
            })
            .and_then(Value::as_object)
            .cloned()
            .ok_or_else(|| format!("{} has no aggregate {:?}", domain, name))
    }
}

fn parse_verb(verb: &str) -> Result<(String, String, String), String> {
    let (path, command) = verb
        .split_once('.')
        .ok_or_else(|| format!("{:?} is not a fully-qualified verb", verb))?;
    let (domain, aggregate) = path
        .split_once("::")
        .ok_or_else(|| format!("{:?} is not a fully-qualified verb", verb))?;

    Ok((domain.to_string(), aggregate.to_string(), command.to_string()))
}

fn find_command(aggregate: &Map<String, Value>, name: &str) -> Option<Map<String, Value>> {
    aggregate
        .get("commands")?
        .as_array()?
        .iter()
        .find(|c| c.get("name").and_then(Value::as_str) == Some(name))?
        .as_object()
        .cloned()
}

pub fn array(node: &Map<String, Value>, key: &str) -> Vec<Value> {
    node.get(key)
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default()
}

pub fn storage_name(name: &str) -> String {
    let mut out = String::new();
    for (index, character) in name.char_indices() {
        if character.is_uppercase() && index > 0 {
            out.push('_');
        }
        out.extend(character.to_lowercase());
    }
    out
}
