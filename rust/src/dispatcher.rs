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

use crate::interp_expr::State;
use crate::interp_givens::evaluate_given;
use crate::interp_mutations::{apply_mutation, assign_creation_attributes, defaults_for};
use serde_json::{json, Map, Value};
use std::collections::BTreeMap;

pub struct Runtime {
    ir: Value,
    store: BTreeMap<String, State>,
    pub events: Vec<Value>,
    minted: usize,
}

impl Runtime {
    pub fn new(ir: Value) -> Self {
        Runtime { ir, store: BTreeMap::new(), events: Vec::new(), minted: 0 }
    }

    pub fn instances(&self) -> &BTreeMap<String, State> {
        &self.store
    }

    pub fn dispatch(&mut self, verb: &str, args: &State) -> Result<State, String> {
        let (domain, aggregate_name, command_name) = parse_verb(verb)?;
        let aggregate = self.find_aggregate(&domain, &aggregate_name)?;
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
            if !evaluate_given(canonical, &state, args) {
                let description = given.get("description").and_then(Value::as_str).unwrap_or("");
                return Err(format!("{} refused — {}", command_name, description));
            }
        }

        if creates {
            assign_creation_attributes(&mut state, &aggregate, &command, args);
        }
        for mutation in array(&command, "mutations") {
            apply_mutation(&mut state, &aggregate, &mutation, args)?;
        }

        let key = format!("{}::{}#{}", domain, aggregate_name, id);
        self.store.insert(key, state.clone());

        // Emitting last: an event is a promise that the state behind it survived.
        for emitted in array(&command, "emits") {
            if let Some(name) = emitted.as_str() {
                self.events.push(json!({
                    "name": name,
                    "aggregate": format!("{}::{}", domain, aggregate_name),
                    "id": id,
                    "payload": Value::Object(args.clone()),
                }));
            }
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

        let key = self
            .store
            .keys()
            .find(|key| key.ends_with(&format!("::{}#{}", aggregate_name, id)))
            .cloned()
            .ok_or_else(|| format!("no {} with {} {:?}", aggregate_name, identity, id))?;

        Ok((id, self.store[&key].clone()))
    }

    fn find_aggregate(&self, domain: &str, name: &str) -> Result<Map<String, Value>, String> {
        let bluebook = self
            .ir
            .get(domain)
            .ok_or_else(|| format!("no domain {:?} in the IR", domain))?;

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
