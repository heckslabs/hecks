
use crate::heki::WriteContext;
use crate::interp_expr::State;
use crate::interp_givens::evaluate_given;
use crate::interp_mutations::{apply_mutation, arithmetic, assign_creation_attributes, defaults_for, resolve_source};
use crate::runtime::PersistenceAdapter;
use crate::value_bridge;
use serde_json::{json, Map, Value};
use std::collections::BTreeMap;

pub struct Runtime {
    ir: Value,
    store: BTreeMap<String, State>,
    adapters: BTreeMap<String, Box<dyn PersistenceAdapter>>,
    pub events: Vec<Value>,
    pub reactions: Vec<Value>,
    pub sagas: Vec<Value>,
    saga_instances: BTreeMap<String, BTreeMap<String, (String, Map<String, Value>)>>,
    minted: usize,
    reaction_depth: usize,
}

const MAX_REACTION_DEPTH: usize = 5;


fn resolve_query_value(value: Option<&Value>, args: &State) -> Value {
    let Some(value) = value else { return Value::Null };
    if let Some(name) = value.as_str().and_then(|s| s.strip_prefix(':')) {
        return args.get(name).cloned().unwrap_or(Value::Null);
    }
    value.clone()
}

fn query_number(value: &Value) -> Option<f64> {
    match value {
        Value::Number(_) => value.as_f64(),
        _ => None,
    }
}

fn query_truthy(value: &Value) -> bool {
    !matches!(value, Value::Null | Value::Bool(false))
}

fn query_text(value: &Value) -> String {
    match value {
        Value::Null => String::new(),
        Value::String(text) => text.clone(),
        Value::Bool(flag) => flag.to_string(),
        other => other.to_string(),
    }
}

fn query_less_than(held: &Value, want: &Value) -> bool {
    match (query_number(held), query_number(want)) {
        (Some(h), Some(w)) => h < w,
        _ => false,
    }
}

fn query_limit(value: &Value) -> usize {
    match value {
        Value::Number(_) => value
            .as_f64()
            .map(|n| if n < 0.0 { 0 } else { n.trunc() as usize })
            .unwrap_or(0),
        Value::String(text) => {
            let trimmed = text.trim_start();
            let digits: String = trimmed.chars().take_while(char::is_ascii_digit).collect();
            digits.parse::<usize>().unwrap_or(0)
        }
        _ => 0,
    }
}

fn query_order(left: &Value, right: &Value) -> std::cmp::Ordering {
    match (query_number(left), query_number(right)) {
        (Some(a), Some(b)) => a.total_cmp(&b),
        (Some(_), None) => std::cmp::Ordering::Less,
        (None, Some(_)) => std::cmp::Ordering::Greater,
        (None, None) => query_text(left).cmp(&query_text(right)),
    }
}

fn admissible_transition(
    aggregate: &Map<String, Value>,
    command_name: &str,
    state: &State,
) -> Result<Option<(String, String)>, String> {
    let Some(lifecycle) = aggregate.get("lifecycle").and_then(Value::as_object) else {
        return Ok(None);
    };
    let field = lifecycle.get("field").and_then(Value::as_str).unwrap_or_default();
    let transitions: Vec<&Value> = lifecycle
        .get("transitions")
        .and_then(Value::as_array)
        .map(|t| {
            t.iter()
                .filter(|t| t.get("command").and_then(Value::as_str) == Some(command_name))
                .collect()
        })
        .unwrap_or_default();
    if transitions.is_empty() {
        return Ok(None);
    }

    let current = state
        .get(field)
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string();
    let admitted = transitions.iter().find(|t| {
        match t.get("from_state") {
            None | Some(Value::Null) => true,
            Some(from) => from.as_str() == Some(current.as_str()),
        }
    });
    if let Some(t) = admitted {
        let to = t.get("to_state").and_then(Value::as_str).unwrap_or_default().to_string();
        return Ok(Some((field.to_string(), to)));
    }

    let mut allowed: Vec<String> = Vec::new();
    for t in &transitions {
        if let Some(from) = t.get("from_state").and_then(Value::as_str) {
            let shown = format!("{from:?}");
            if !allowed.contains(&shown) {
                allowed.push(shown);
            }
        }
    }
    Err(format!(
        "{command_name} refused — {field} is {current:?}, and {command_name} moves it only from {}",
        allowed.join(" or ")
    ))
}

impl Runtime {
    pub fn new(ir: Value) -> Self {
        Runtime {
            ir,
            store: BTreeMap::new(),
            adapters: BTreeMap::new(),
            events: Vec::new(),
            reactions: Vec::new(),
            sagas: Vec::new(),
            saga_instances: BTreeMap::new(),
            minted: 0,
            reaction_depth: 0,
        }
    }

    pub fn attach(&mut self, aggregate: &str, adapter: Box<dyn PersistenceAdapter>) {
        self.adapters.insert(aggregate.to_string(), adapter);
    }

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

    fn dispatch_entity(
        &mut self,
        domain: &str,
        aggregate_name: &str,
        dotted: &str,
        args: &State,
    ) -> Result<State, String> {
        let (entity_name, command_name) = crate::naming::split_dotted(dotted);
        let aggregate = self.find_aggregate(domain, aggregate_name, dotted)?;
        let entity = array(&aggregate, "entities")
            .into_iter()
            .find(|e| e.get("name").and_then(Value::as_str) == Some(entity_name))
            .and_then(|e| e.as_object().cloned())
            .ok_or_else(|| format!("{} has no entity {:?}", aggregate_name, entity_name))?;
        let command = array(&entity, "commands")
            .into_iter()
            .find(|c| c.get("name").and_then(Value::as_str) == Some(command_name))
            .and_then(|c| c.as_object().cloned())
            .ok_or_else(|| format!("{} has no command {:?}", entity_name, command_name))?;

        let identity = aggregate
            .get("identified_by")
            .and_then(Value::as_str)
            .unwrap_or("id")
            .to_string();
        let parent_id = args
            .get(&identity)
            .or_else(|| args.get("id"))
            .and_then(Value::as_str)
            .map(str::to_string)
            .ok_or_else(|| {
                format!("{command_name} acts on a {aggregate_name}'s {entity_name} — pass {identity}:")
            })?;

        let mut state = if let Some(adapter) = self.adapters.get(aggregate_name) {
            adapter
                .find(&parent_id)
                .map(value_bridge::from_state)
                .ok_or_else(|| format!("no {} with {} {:?}", aggregate_name, identity, parent_id))?
        } else {
            let key = format!("{}::{}#{}", domain, aggregate_name, parent_id);
            self.store
                .get(&key)
                .cloned()
                .ok_or_else(|| format!("no {} with {} {:?}", aggregate_name, identity, parent_id))?
        };

        let list_attr = array(&aggregate, "attributes")
            .into_iter()
            .filter_map(|a| a.as_object().cloned())
            .find(|a| {
                a.get("list").and_then(Value::as_bool).unwrap_or(false)
                    && a.get("type").and_then(Value::as_str) == Some(entity_name)
            })
            .and_then(|a| a.get("name").and_then(Value::as_str).map(str::to_string))
            .ok_or_else(|| format!("{} holds no list of {}", aggregate_name, entity_name))?;

        let entity_key = entity
            .get("identified_by")
            .and_then(Value::as_str)
            .unwrap_or("id")
            .to_string();
        let want = args
            .get(&entity_key)
            .cloned()
            .ok_or_else(|| format!("{command_name} acts on one {entity_name} — pass {entity_key}:"))?;

        let mut elements = state
            .get(&list_attr)
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
        let position = elements
            .iter()
            .position(|el| el.get(&entity_key) == Some(&want))
            .ok_or_else(|| {
                format!(
                    "no {} with {} {} on {} {:?}",
                    entity_name, entity_key, want, aggregate_name, parent_id
                )
            })?;
        let mut element = elements[position]
            .as_object()
            .cloned()
            .unwrap_or_default();

        for given in array(&command, "givens") {
            let canonical = given.get("canonical").and_then(Value::as_str).unwrap_or("");
            if !evaluate_given(canonical, &element, args)? {
                let description = given.get("description").and_then(Value::as_str).unwrap_or("");
                return Err(format!("{} refused — {}", command_name, description));
            }
        }
        let transition_to = admissible_transition(&entity, command_name, &element)?;

        for mutation in array(&command, "mutations") {
            let target = mutation
                .get("target")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string();
            match mutation.get("op").and_then(Value::as_str) {
                Some("increment") | Some("decrement") => {
                    let operation = mutation.get("op").and_then(Value::as_str).unwrap_or("increment");
                    let updated = arithmetic(&element, &target, operation, &mutation, args)?;
                    element.insert(target, updated);
                }
                _ => {
                    element.insert(target, resolve_source(&mutation, args));
                }
            }
        }
        if let Some((field, to_state)) = transition_to {
            element.insert(field, Value::String(to_state));
        }

        elements[position] = Value::Object(element);
        state.insert(list_attr, Value::Array(elements));

        match self.adapters.get_mut(aggregate_name) {
            Some(adapter) => adapter.save(
                value_bridge::to_state(&parent_id, &state),
                WriteContext::Dispatch { aggregate: aggregate_name, command: command_name },
            ),
            None => {
                let key = format!("{}::{}#{}", domain, aggregate_name, parent_id);
                self.store.insert(key, state.clone());
            }
        }

        let mut announced: Vec<Value> = Vec::new();
        for emitted in array(&command, "emits") {
            if let Some(name) = emitted.as_str() {
                let event = json!({
                    "name": name,
                    "aggregate": format!("{}::{}", domain, aggregate_name),
                    "id": parent_id,
                    "payload": Value::Object(args.clone()),
                });
                self.events.push(event.clone());
                announced.push(event);
            }
        }
        for event in &announced {
            self.react_to(event, domain);
        }
        for event in &announced {
            self.advance_sagas(event, domain);
        }

        let mut result = state;
        result.insert(identity, Value::String(parent_id));
        Ok(result)
    }

    pub fn query(&mut self, verb: &str, args: &State) -> Result<Vec<Value>, String> {
        let (domain, aggregate_name, query_name) = parse_verb(verb)?;
        let aggregate = self.find_aggregate(&domain, &aggregate_name, verb)?;
        if query_name.contains('.') {
            return self.query_entity(&domain, &aggregate_name, &aggregate, &query_name, args);
        }
        let declared = array(&aggregate, "queries")
            .into_iter()
            .find(|q| q.get("name").and_then(Value::as_str) == Some(query_name.as_str()))
            .and_then(|q| q.as_object().cloned())
            .ok_or_else(|| format!("{} has no query {:?}", aggregate_name, query_name))?;

        let mut matched: Vec<(String, State)> = Vec::new();
        for (key, state) in self.all_records(&domain, &aggregate_name, &aggregate) {
            let holds = array(&declared, "wheres").iter().all(|clause| {
                let field = clause.get("field").and_then(Value::as_str).unwrap_or_default();
                let held = state.get(field).cloned().unwrap_or(Value::Null);
                let want = resolve_query_value(clause.get("value"), args);
                match clause.get("op").and_then(Value::as_str) {
                    Some("lt") => query_less_than(&held, &want),
                    _ => held == want,
                }
            });
            if holds {
                matched.push((key, state));
            }
        }

        if let Some(order) = declared.get("order_by").and_then(Value::as_object) {
            let field = order.get("field").and_then(Value::as_str).unwrap_or_default().to_string();
            matched.sort_by(|(a_id, a), (b_id, b)| {
                let left = a.get(&field).cloned().unwrap_or(Value::Null);
                let right = b.get(&field).cloned().unwrap_or(Value::Null);
                query_order(&left, &right).then_with(|| a_id.cmp(b_id))
            });
            if order.get("direction").and_then(Value::as_str) == Some("desc") {
                matched.reverse();
            }
        }

        let capped: Vec<(String, State)> = match declared.get("limit").and_then(|l| l.get("value")) {
            Some(limit) => {
                let n = query_limit(&resolve_query_value(Some(limit), args));
                matched.into_iter().take(n).collect()
            }
            None => matched,
        };

        Ok(capped
            .into_iter()
            .map(|(id, state)| {
                let mut row = Map::new();
                row.insert("id".to_string(), Value::String(id));
                for (k, v) in state {
                    row.insert(k, v);
                }
                Value::Object(row)
            })
            .collect())
    }

    fn query_entity(
        &mut self,
        domain: &str,
        aggregate_name: &str,
        aggregate: &Map<String, Value>,
        dotted: &str,
        args: &State,
    ) -> Result<Vec<Value>, String> {
        let (entity_name, query_name) = crate::naming::split_dotted(dotted);
        let entity = array(aggregate, "entities")
            .into_iter()
            .find(|e| e.get("name").and_then(Value::as_str) == Some(entity_name))
            .and_then(|e| e.as_object().cloned())
            .ok_or_else(|| format!("{} has no entity {:?}", aggregate_name, entity_name))?;
        let declared = array(&entity, "queries")
            .into_iter()
            .find(|q| q.get("name").and_then(Value::as_str) == Some(query_name))
            .and_then(|q| q.as_object().cloned())
            .ok_or_else(|| format!("{} has no query {:?}", entity_name, query_name))?;
        let list_attr = array(aggregate, "attributes")
            .into_iter()
            .filter_map(|a| a.as_object().cloned())
            .find(|a| {
                a.get("list").and_then(Value::as_bool).unwrap_or(false)
                    && a.get("type").and_then(Value::as_str) == Some(entity_name)
            })
            .and_then(|a| a.get("name").and_then(Value::as_str).map(str::to_string))
            .ok_or_else(|| format!("{} holds no list of {}", aggregate_name, entity_name))?;

        let parent_key = crate::naming::reference_key(aggregate_name);
        let mut rows: Vec<Value> = Vec::new();
        for (parent_id, state) in self.all_records(domain, aggregate_name, aggregate) {
            for element in state.get(&list_attr).and_then(Value::as_array).cloned().unwrap_or_default() {
                let Some(element) = element.as_object() else { continue };
                let holds = array(&declared, "wheres").iter().all(|clause| {
                    let field = clause.get("field").and_then(Value::as_str).unwrap_or_default();
                    let held = element.get(field).cloned().unwrap_or(Value::Null);
                    let want = resolve_query_value(clause.get("value"), args);
                    match clause.get("op").and_then(Value::as_str) {
                        Some("lt") => query_less_than(&held, &want),
                        _ => held == want,
                    }
                });
                if holds {
                    let mut row = Map::new();
                    row.insert(parent_key.clone(), Value::String(parent_id.clone()));
                    for (k, v) in element {
                        row.insert(k.clone(), v.clone());
                    }
                    rows.push(Value::Object(row));
                }
            }
        }

        if let Some(order) = declared.get("order_by").and_then(Value::as_object) {
            let field = order.get("field").and_then(Value::as_str).unwrap_or_default().to_string();
            rows.sort_by(|a, b| {
                let left = a.get(&field).cloned().unwrap_or(Value::Null);
                let right = b.get(&field).cloned().unwrap_or(Value::Null);
                query_order(&left, &right)
            });
            if order.get("direction").and_then(Value::as_str) == Some("desc") {
                rows.reverse();
            }
        }
        if let Some(limit) = declared.get("limit").and_then(|l| l.get("value")) {
            rows.truncate(query_limit(&resolve_query_value(Some(limit), args)));
        }
        Ok(rows)
    }

    fn all_records(
        &mut self,
        domain: &str,
        aggregate_name: &str,
        _aggregate: &Map<String, Value>,
    ) -> Vec<(String, State)> {
        if let Some(adapter) = self.adapters.get(aggregate_name) {
            return adapter
                .all()
                .into_iter()
                .map(|s| (s.id.clone(), value_bridge::from_state(s)))
                .collect();
        }
        let prefix = format!("{}::{}#", domain, aggregate_name);
        self.store
            .iter()
            .filter(|(key, _)| key.starts_with(&prefix))
            .map(|(key, state)| (key[prefix.len()..].to_string(), state.clone()))
            .collect()
    }

    pub fn dispatch(&mut self, verb: &str, args: &State) -> Result<State, String> {
        let (domain, aggregate_name, command_name) = parse_verb(verb)?;
        if command_name.contains('.') {
            return self.dispatch_entity(&domain, &aggregate_name, &command_name, args);
        }
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

        for given in array(&command, "givens") {
            let canonical = given.get("canonical").and_then(Value::as_str).unwrap_or("");
            if !evaluate_given(canonical, &state, args)? {
                let description = given.get("description").and_then(Value::as_str).unwrap_or("");
                return Err(format!("{} refused — {}", command_name, description));
            }
        }

        let transition_to = admissible_transition(&aggregate, &command_name, &state)?;

        if creates {
            assign_creation_attributes(&mut state, &aggregate, &command, args)?;
        }
        for mutation in array(&command, "mutations") {
            apply_mutation(&mut state, &aggregate, &mutation, args)?;
        }
        if let Some((field, to_state)) = transition_to {
            state.insert(field, Value::String(to_state));
        }

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

        let mut announced: Vec<Value> = Vec::new();
        for emitted in array(&command, "emits") {
            if let Some(name) = emitted.as_str() {
                let event = json!({
                    "name": name,
                    "aggregate": format!("{}::{}", domain, aggregate_name),
                    "id": id,
                    "payload": Value::Object(args.clone()),
                });

                self.events.push(event.clone());
                announced.push(event);
            }
        }

        for event in &announced {
            self.react_to(event, &domain);
        }

        for event in &announced {
            self.advance_sagas(event, &domain);
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
                .filter(|value| query_truthy(value))
                .map(query_text)
                .unwrap_or_else(|| {
                    self.minted += 1;
                    format!("{}-{}", crate::naming::snake(&aggregate_name), self.minted)
                });
            return Ok((id, defaults_for(aggregate)));
        }

        let reference_key = command
            .get("references")
            .and_then(Value::as_str)
            .map(crate::naming::reference_key)
            .unwrap_or_default();
        let id = [identity, "id", reference_key.as_str()]
            .into_iter()
            .filter_map(|key| args.get(key))
            .find(|value| query_truthy(value))
            .map(query_text)
            .ok_or_else(|| format!("{} acts on an existing {} — pass {}:", command_name, aggregate_name, identity))?;

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

    fn react_to(&mut self, event: &Value, domain: &str) {
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
                Err(reason) => {
                    entry.insert("delivered".into(), Value::Bool(false));
                    entry.insert("reason".into(), Value::String(reason));
                }
            }

            self.reactions.push(record);
        }
    }

    fn advance_sagas(&mut self, event: &Value, domain: &str) {
        let pms = self
            .ir
            .get(domain)
            .and_then(|bluebook| bluebook.get("process_managers"))
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();

        for pm in &pms {
            self.begin_saga(pm, event);
            self.advance_saga(pm, event, domain);
            self.end_saga(pm, event);
        }
    }

    fn correlation(pm: &Value, event: &Value) -> Option<String> {
        let field = pm.get("correlates_by").and_then(Value::as_str)?;
        if let Some(value) = event.get("payload").and_then(|p| p.get(field)) {
            if !value.is_null() {
                let text = value.as_str().map(str::to_string).unwrap_or_else(|| value.to_string());
                if !text.is_empty() {
                    return Some(text);
                }
            }
        }

        let own_key = event
            .get("aggregate")
            .and_then(Value::as_str)
            .map(crate::naming::reference_key)
            .unwrap_or_default();
        if own_key != field {
            return None;
        }
        let id = event.get("id").and_then(Value::as_str).unwrap_or_default();
        if id.is_empty() { None } else { Some(id.to_string()) }
    }

    fn begin_saga(&mut self, pm: &Value, event: &Value) {
        let name = pm.get("name").and_then(Value::as_str).unwrap_or_default().to_string();
        let event_name = event.get("name").and_then(Value::as_str).unwrap_or_default();
        if Some(event_name) != pm.get("starts_on").and_then(Value::as_str) {
            return;
        }

        let Some(correlation) = Self::correlation(pm, event) else {
            let field = pm.get("correlates_by").and_then(Value::as_str).unwrap_or_default();
            self.sagas.push(json!({
                "process_manager": name, "on": event_name,
                "born": false, "reason": format!("no {field} in the payload"),
            }));
            return;
        };
        if self.saga_instances.get(&name).is_some_and(|t| t.contains_key(&correlation)) {
            return;
        }

        let first_state = pm
            .get("states")
            .and_then(Value::as_array)
            .and_then(|s| s.first())
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string();
        let memory = event
            .get("payload")
            .and_then(Value::as_object)
            .cloned()
            .unwrap_or_default();

        self.saga_instances
            .entry(name.clone())
            .or_default()
            .insert(correlation.clone(), (first_state.clone(), memory));
        self.sagas.push(json!({
            "process_manager": name, "on": event_name,
            "instance": correlation, "born": true, "state": first_state,
        }));
    }

    fn advance_saga(&mut self, pm: &Value, event: &Value, domain: &str) {
        let pm_name = pm.get("name").and_then(Value::as_str).unwrap_or_default().to_string();
        let event_name = event.get("name").and_then(Value::as_str).unwrap_or_default().to_string();
        let Some(handler) = pm
            .get("handlers")
            .and_then(Value::as_array)
            .and_then(|hs| {
                hs.iter()
                    .find(|h| h.get("event_type").and_then(Value::as_str) == Some(event_name.as_str()))
            })
            .cloned()
        else {
            return;
        };
        let Some(correlation) = Self::correlation(pm, event) else { return };

        let from = handler.get("from_state").and_then(Value::as_str).unwrap_or_default().to_string();
        let to = handler.get("to_state").and_then(Value::as_str).unwrap_or_default().to_string();

        let Some((state, memory)) = self
            .saga_instances
            .get(&pm_name)
            .and_then(|t| t.get(&correlation))
            .cloned()
        else {
            self.sagas.push(json!({
                "process_manager": pm_name, "on": event_name, "instance": correlation,
                "advanced": false, "reason": format!("no conversation remembers {correlation:?}"),
            }));
            return;
        };
        if state != from {
            self.sagas.push(json!({
                "process_manager": pm_name, "on": event_name, "instance": correlation,
                "advanced": false, "reason": format!("in {state:?}, not {from:?}"),
            }));
            return;
        }

        if let Some(instance) = self
            .saga_instances
            .get_mut(&pm_name)
            .and_then(|t| t.get_mut(&correlation))
        {
            instance.0 = to.clone();
        }
        self.sagas.push(json!({
            "process_manager": pm_name, "on": event_name, "instance": correlation,
            "advanced": true, "from": from, "to": to,
        }));

        let dispatches = handler
            .get("dispatches")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
        for spec in &dispatches {
            self.deliver_saga_dispatch(&pm_name, spec, event, &memory, &correlation, domain);
        }
    }

    fn deliver_saga_dispatch(
        &mut self,
        pm_name: &str,
        spec: &Value,
        event: &Value,
        memory: &Map<String, Value>,
        correlation: &str,
        domain: &str,
    ) {
        let command = spec.get("command_name").and_then(Value::as_str).unwrap_or_default();
        let payload = event
            .get("payload")
            .and_then(Value::as_object)
            .cloned()
            .unwrap_or_default();

        let correlates_by = self
            .ir
            .get(domain)
            .and_then(|b| b.get("process_managers"))
            .and_then(Value::as_array)
            .and_then(|pms| {
                pms.iter()
                    .find(|p| p.get("name").and_then(Value::as_str) == Some(pm_name))
            })
            .and_then(|p| p.get("correlates_by"))
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string();
        let mut args = Map::new();
        for pair in spec.get("with").and_then(Value::as_array).cloned().unwrap_or_default() {
            let (Some(key), Some(token)) = (
                pair.get(0).and_then(Value::as_str),
                pair.get(1).and_then(Value::as_str),
            ) else {
                continue;
            };
            let value = match token.strip_prefix(':') {
                Some(name) if name == correlates_by => Value::String(correlation.to_string()),
                Some(name) => payload
                    .get(name)
                    .or_else(|| memory.get(name))
                    .cloned()
                    .unwrap_or(Value::Null),
                None => Value::String(token.to_string()),
            };
            args.insert(key.to_string(), value);
        }

        let target = if command.contains("::") {
            command.to_string()
        } else {
            format!("{domain}::{command}")
        };
        let mut record = json!({
            "process_manager": pm_name, "instance": correlation, "dispatch": command,
        });

        let outcome = if self.reaction_depth >= MAX_REACTION_DEPTH {
            Err(format!("reaction depth {MAX_REACTION_DEPTH} reached"))
        } else {
            self.reaction_depth += 1;
            let result = self.dispatch(&target, &args);
            self.reaction_depth -= 1;
            result.map(|_| ())
        };

        let entry = record.as_object_mut().expect("record is an object");
        match outcome {
            Ok(()) => {
                entry.insert("delivered".into(), Value::Bool(true));
            }
            Err(reason) => {
                entry.insert("delivered".into(), Value::Bool(false));
                entry.insert("reason".into(), Value::String(reason));
            }
        }
        self.sagas.push(record);
    }

    fn end_saga(&mut self, pm: &Value, event: &Value) {
        let name = pm.get("name").and_then(Value::as_str).unwrap_or_default().to_string();
        let event_name = event.get("name").and_then(Value::as_str).unwrap_or_default();
        if Some(event_name) != pm.get("ends_on").and_then(Value::as_str) {
            return;
        }
        let Some(correlation) = Self::correlation(pm, event) else { return };
        if self
            .saga_instances
            .get_mut(&name)
            .and_then(|t| t.remove(&correlation))
            .is_none()
        {
            return;
        }

        self.sagas.push(json!({
            "process_manager": name, "on": event_name,
            "instance": correlation, "ended": true,
        }));
    }

    fn policies_for(&self, event: &Value, domain: &str) -> Vec<(String, String)> {
        let Some(name) = event.get("name").and_then(Value::as_str) else {
            return Vec::new();
        };
        let emitting = event
            .get("aggregate")
            .and_then(Value::as_str)
            .map(crate::naming::demodulise)
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
                let qualifier = crate::naming::qualifier(on_event);
                let event_name = crate::naming::unqualified(on_event);

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
    let (domain, aggregate, command) = crate::naming::split_verb(verb)
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


#[cfg(test)]
mod query_semantics_tests {
    use super::*;
    use serde_json::json;
    use std::cmp::Ordering;

    #[test]
    fn text_of_nothing_is_empty_not_the_word_null() {
        assert_eq!(query_text(&Value::Null), "");
        assert_eq!(query_text(&json!("abc")), "abc");
        assert_eq!(query_text(&json!(true)), "true");
        assert_eq!(query_text(&json!(false)), "false");
    }

    #[test]
    fn numbers_sort_before_everything_else() {
        assert_eq!(query_order(&json!(1), &json!("a")), Ordering::Less);
        assert_eq!(query_order(&json!("a"), &json!(1)), Ordering::Greater);
    }

    #[test]
    fn floats_are_numbers_too() {
        assert_eq!(query_order(&json!(9.5), &json!(10.0)), Ordering::Less);
        assert_eq!(query_order(&json!(10.0), &json!(9.5)), Ordering::Greater);
        assert_eq!(query_order(&json!(2), &json!(10.0)), Ordering::Less);
    }

    #[test]
    fn a_missing_field_sorts_as_empty_text() {
        assert_eq!(query_order(&Value::Null, &json!("a")), Ordering::Less);
        assert_eq!(query_order(&Value::Null, &Value::Null), Ordering::Equal);
    }

    #[test]
    fn less_than_needs_two_numbers() {
        assert!(query_less_than(&json!(1), &json!(2)));
        assert!(query_less_than(&json!(9.5), &json!(10)));
        assert!(!query_less_than(&json!("a"), &json!("b")));
        assert!(!query_less_than(&json!(1), &json!("2")));
        assert!(!query_less_than(&Value::Null, &json!(1)));
    }

    #[test]
    fn a_limit_reads_as_ruby_to_i() {
        assert_eq!(query_limit(&Value::Null), 0);
        assert_eq!(query_limit(&json!(5)), 5);
        assert_eq!(query_limit(&json!("5")), 5);
        assert_eq!(query_limit(&json!("abc")), 0);
        assert_eq!(query_limit(&json!(5.9)), 5);
        assert_eq!(query_limit(&json!(true)), 0);
    }

    #[test]
    fn only_nothing_and_false_are_falsy() {
        assert!(!query_truthy(&Value::Null));
        assert!(!query_truthy(&json!(false)));
        assert!(query_truthy(&json!(0)));
        assert!(query_truthy(&json!("")));
        assert!(query_truthy(&json!(true)));
    }
}
