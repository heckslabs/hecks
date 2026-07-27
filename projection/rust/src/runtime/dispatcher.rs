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
use crate::interp_mutations::{apply_mutation, arithmetic, assign_creation_attributes, defaults_for, resolve_source};
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
    /// Every process-manager step — born, advanced, refused, ended. The
    /// projection of Ruby's `registry.saga_log` : Settlement parsed, both
    /// parsers agreed on it byte-for-byte, and it ran NOWHERE. A saga the
    /// contract does not compare is a saga that can silently stop again.
    pub sagas: Vec<Value>,
    /// Live conversations : pm name → correlation → (state, remembered opening
    /// payload). Memory is the STARTING event's payload — a saga exists because
    /// something has to remember which half is done.
    saga_instances: BTreeMap<String, BTreeMap<String, (String, Map<String, Value>)>>,
    minted: usize,
    /// How deep the current reaction chain is. A policy whose command emits the
    /// event it waits for would react for ever ; bounded rather than detected,
    /// because the cycle is a modelling error and the runtime's job is to stop
    /// rather than to diagnose.
    reaction_depth: usize,
}

/// Mirrors Ruby's MAX_REACTION_DEPTH.
const MAX_REACTION_DEPTH: usize = 5;

/// "LedgerEntry" → "ledger_entry" — the reference-key spelling used by
/// correlation fallback, hydrate, and entity-query parent keys alike.
fn snake_case(name: &str) -> String {
    let mut key = String::new();
    for (i, c) in name.chars().enumerate() {
        if c.is_ascii_uppercase() {
            if i > 0 {
                key.push('_');
            }
            key.push(c.to_ascii_lowercase());
        } else {
            key.push(c);
        }
    }
    key
}

/// A query-clause value : ":symbol" reads the caller's argument of that
/// name ; anything else is the literal itself. The projection of Ruby's
/// `resolve_query_value`.
fn resolve_query_value(value: Option<&Value>, args: &State) -> Value {
    let Some(value) = value else { return Value::Null };
    if let Some(name) = value.as_str().and_then(|s| s.strip_prefix(':')) {
        return args.get(name).cloned().unwrap_or(Value::Null);
    }
    value.clone()
}

/// The lifecycle's admission rule — the projection of Ruby's
/// `admissible_transition`. None when the command is not part of the machine ;
/// Some((field, to_state)) when admitted ; Err when the machine says no. A
/// transition whose from_state is null admits any state. The canonical IR is
/// already flat — one record per (command, to, from) — so admission is a scan.
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

    /// An entity command — the projection of Ruby's `dispatch_entity` :
    /// hydrate the PARENT, address ONE element of the list holding this
    /// entity's records by the entity's own identified_by, gate its
    /// lifecycle, mutate THAT element, save the parent, announce
    /// parent-tagged. DELIBERATE DIVERGENCE FROM HECKS, noted where it is
    /// visible : hecks runs an entity command against the parent record
    /// itself ("entities live within the parent's record"), which would
    /// write Reverse's narrative onto the Account — runnable, but not what
    /// "undo ONE movement" declares. Addressing the element is what the
    /// Entity IR's own docstring promises (`Order.OrderLine.Restock`).
    fn dispatch_entity(
        &mut self,
        domain: &str,
        aggregate_name: &str,
        dotted: &str,
        args: &State,
    ) -> Result<State, String> {
        let (entity_name, command_name) = dotted.split_once('.').unwrap_or((dotted, ""));
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

        // The parent, through the bound adapter — same wording as hydrate.
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

        // Givens, the state machine, then the mutations — the exact pipeline,
        // one element deep. Wordings shared with the aggregate path.
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
                    // Values store RAW — the append path stores an element's
                    // fields as they arrive, and one entry VO-wrapped by a
                    // later Reverse beside ten raw siblings would be two
                    // shapes for one column. Mirrors Ruby's apply_to_element.
                    element.insert(target, resolve_source(&mutation, args));
                }
            }
        }
        if let Some((field, to_state)) = transition_to {
            element.insert(field, Value::String(to_state));
        }

        elements[position] = Value::Object(element);
        state.insert(list_attr, Value::Array(elements));

        // PERSIST, then announce — the same order and the same reasons.
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

    /// THE QUESTIONS, finally answered — the projection of Ruby's `query`.
    /// eq and lt are the whole vocabulary ; a clause value is a literal or a
    /// ":symbol" naming one of the query's own attributes, resolved from the
    /// caller. Numeric fields sort as numbers, everything else as text, ties
    /// break on id, `desc` reverses whole — spelled identically to Ruby's
    /// `ordered`, because two runtimes sorting differently is ordering noise
    /// the harness would drown in.
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
                    Some("lt") => match (held.as_i64(), want.as_i64()) {
                        (Some(h), Some(w)) => h < w,
                        _ => false,
                    },
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
                let rank = |s: &State, id: &String| {
                    let v = s.get(&field).cloned().unwrap_or(Value::Null);
                    match v.as_i64() {
                        Some(n) => (0i64, n, String::new(), id.clone()),
                        None => (
                            1i64,
                            0,
                            v.as_str().map(str::to_string).unwrap_or_else(|| v.to_string()),
                            id.clone(),
                        ),
                    }
                };
                rank(a, a_id).cmp(&rank(b, b_id))
            });
            if order.get("direction").and_then(Value::as_str) == Some("desc") {
                matched.reverse();
            }
        }

        let capped: Vec<(String, State)> = match declared.get("limit").and_then(|l| l.get("value")) {
            Some(limit) => {
                let n = resolve_query_value(Some(limit), args)
                    .as_str()
                    .and_then(|s| s.parse::<usize>().ok())
                    .or_else(|| resolve_query_value(Some(limit), args).as_u64().map(|v| v as usize))
                    .unwrap_or(usize::MAX);
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

    /// An entity query — the projection of Ruby's `query_entity` : elements
    /// across every parent record, each row the element plus the parent's id
    /// under the parent's snake_case name, because an element's address
    /// outside the boundary always includes whose boundary it is.
    fn query_entity(
        &mut self,
        domain: &str,
        aggregate_name: &str,
        aggregate: &Map<String, Value>,
        dotted: &str,
        args: &State,
    ) -> Result<Vec<Value>, String> {
        let (entity_name, query_name) = dotted.split_once('.').unwrap_or((dotted, ""));
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

        let parent_key = snake_case(aggregate_name);
        let mut rows: Vec<Value> = Vec::new();
        for (parent_id, state) in self.all_records(domain, aggregate_name, aggregate) {
            for element in state.get(&list_attr).and_then(Value::as_array).cloned().unwrap_or_default() {
                let Some(element) = element.as_object() else { continue };
                let holds = array(&declared, "wheres").iter().all(|clause| {
                    let field = clause.get("field").and_then(Value::as_str).unwrap_or_default();
                    let held = element.get(field).cloned().unwrap_or(Value::Null);
                    let want = resolve_query_value(clause.get("value"), args);
                    match clause.get("op").and_then(Value::as_str) {
                        Some("lt") => match (held.as_i64(), want.as_i64()) {
                            (Some(h), Some(w)) => h < w,
                            _ => false,
                        },
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
                let rank = |row: &Value| {
                    let v = row.get(&field).cloned().unwrap_or(Value::Null);
                    match v.as_i64() {
                        Some(n) => (0i64, n, String::new()),
                        None => (1i64, 0, v.as_str().map(str::to_string).unwrap_or_else(|| v.to_string())),
                    }
                };
                rank(a).cmp(&rank(b))
            });
            if order.get("direction").and_then(Value::as_str) == Some("desc") {
                rows.reverse();
            }
        }
        if let Some(limit) = declared.get("limit").and_then(|l| l.get("value")) {
            if let Some(n) = resolve_query_value(Some(limit), args)
                .as_str()
                .and_then(|s| s.parse::<usize>().ok())
            {
                rows.truncate(n);
            }
        }
        Ok(rows)
    }

    /// Every stored record of one aggregate, as (bare id, state) — through
    /// the bound adapter when there is one, same as `instances`.
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
        // `Order.OrderLine.Restock` — an entity is addressed THROUGH the
        // parent, never around it. The projection of Ruby's dispatch_entity.
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

        // Guard before anything is written, so a refused command leaves no trace.
        for given in array(&command, "givens") {
            let canonical = given.get("canonical").and_then(Value::as_str).unwrap_or("");
            if !evaluate_given(canonical, &state, args)? {
                let description = given.get("description").and_then(Value::as_str).unwrap_or("");
                return Err(format!("{} refused — {}", command_name, description));
            }
        }

        // The state machine gates BEFORE anything is written and moves AFTER
        // the mutations land. The projection of Ruby's `admissible_transition` —
        // wording to the character, because a refusal the two runtimes phrase
        // differently is a diff the harness has to explain away.
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

        // REMEMBER - a process manager is the conversation that outlives any
        // one command. After the reflexes, and after react_to, so a policy's
        // reaction and a saga's advance read the same event in a fixed order
        // on both runtimes. The projection of Ruby's `advance_sagas`.
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
                .and_then(Value::as_str)
                .map(str::to_string)
                .unwrap_or_else(|| {
                    self.minted += 1;
                    format!("{}-{}", storage_name(&aggregate_name), self.minted)
                });
            return Ok((id, defaults_for(aggregate)));
        }

        // Three spellings address a record, in order : the natural key
        // (identified_by), the universal `id:`, and the REFERENCE KEY — the
        // snake_case of the aggregate `reference_to` names, so Reverse takes
        // `transfer:`. The projection of Ruby's hydrate ; only the first
        // spelling resolved before, and the whole saga surface refused with
        // "pass id:" in both runtimes — 21 agreeing refusals that looked like
        // a passing suite.
        let reference_key = command
            .get("references")
            .and_then(Value::as_str)
            .map(|target| {
                let mut key = String::new();
                for (i, c) in target.chars().enumerate() {
                    if c.is_ascii_uppercase() {
                        if i > 0 {
                            key.push('_');
                        }
                        key.push(c.to_ascii_lowercase());
                    } else {
                        key.push(c);
                    }
                }
                key
            })
            .unwrap_or_default();
        let id = args
            .get(identity)
            .or_else(|| args.get("id"))
            .or_else(|| args.get(&reference_key))
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
    // ======================================================================
    // THE CONVERSATION THAT OUTLIVES A COMMAND — the projection of Ruby's
    // saga engine (lib/hecksagain/runtime/dispatcher.rb holds the semantics
    // and the doctrine comment ; this is the mirror, step for step) :
    // born → advanced (transition FIRST, then dispatches ; `with:` symbols
    // read the event payload first, the remembered opening payload second)
    // → refused dispatches recorded, never propagated → ended on ends_on.
    // ======================================================================
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

    /// The projection of Ruby's `saga_correlation` : the payload's
    /// correlates_by field when it rides there — and when the field NAMES THE
    /// EMITTING AGGREGATE (correlates_by :transfer, event from Transfer), the
    /// event's own id IS that value, because `transfer` is the reference-key
    /// spelling of a Transfer's identity everywhere else in the language.
    fn correlation(pm: &Value, event: &Value) -> Option<String> {
        let field = pm.get("correlates_by").and_then(Value::as_str)?;
        if let Some(value) = event.get("payload").and_then(|p| p.get(field)) {
            // Null is ABSENT, not the four-letter string "null" — Ruby's nil
            // reads as no-correlation, and a saga keyed by "null" would be a
            // conversation with a ghost.
            if !value.is_null() {
                let text = value.as_str().map(str::to_string).unwrap_or_else(|| value.to_string());
                if !text.is_empty() {
                    return Some(text);
                }
            }
        }

        let emitting = event
            .get("aggregate")
            .and_then(Value::as_str)
            .and_then(|fqn| fqn.rsplit("::").next())
            .unwrap_or_default();
        let mut own_key = String::new();
        for (i, c) in emitting.chars().enumerate() {
            if c.is_ascii_uppercase() {
                if i > 0 {
                    own_key.push('_');
                }
                own_key.push(c.to_ascii_lowercase());
            } else {
                own_key.push(c);
            }
        }
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

        // Transition FIRST — a dispatch below can cascade back into this saga
        // (Credit → AccountCredited), and the nested advance must see the new
        // state, not the one it is leaving.
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

        // `with:` values ride the canonical IR spelling : a leading ':' names a
        // key to READ — the conversation's own name when it IS the
        // correlates_by field (inside this saga `:transfer` means exactly the
        // correlation), then the triggering event's payload, then the
        // remembered opening payload — and anything else is a literal to write.
        // The projection of Ruby's resolution order, exactly.
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
