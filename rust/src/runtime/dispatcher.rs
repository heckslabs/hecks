use crate::heki::WriteContext;
use crate::interp_expr::State;
use crate::interp_givens::evaluate_given;
use crate::interp_mutations::{
    apply_mutation, arithmetic, assign_creation_attributes, coerce_attribute, defaults_for,
    normalize_command_args, refuse_unknown_arguments, resolve_source,
};
use crate::runtime::PersistenceAdapter;
use crate::value_bridge;
use serde_json::{json, Map, Value};
use std::cell::RefCell;
use std::collections::{BTreeMap, HashMap};
use std::fs;
use std::sync::Arc;

pub struct Runtime {
    ir: Value,
    store: BTreeMap<String, State>,
    adapters: BTreeMap<String, Box<dyn PersistenceAdapter>>,
    mirrors: BTreeMap<String, Vec<(String, Box<dyn PersistenceAdapter>)>>,
    pub events: Vec<Value>,
    pub reactions: Vec<Value>,
    pub sagas: Vec<Value>,
    saga_instances: BTreeMap<String, BTreeMap<String, (String, Map<String, Value>)>>,
    reaction_depth: usize,
    // Set by a test to observe dispatch order (Vocabulary::AggregateDispatchOrder /
    // EntityDispatchOrder in language/bluebook.bluebook) ; None in production,
    // always — one Vec push and a match per step is the entire cost of leaving
    // this in. Mirrors CommandInterpreter.trace / EntityInterpreter.trace on
    // the Ruby side.
    pub dispatch_trace: Option<Vec<&'static str>>,
    // Resolved aggregate/entity/command/query/domain subtrees, keyed by a
    // discriminated string ("aggregate:{domain}:{name}", etc.) — `ir` is set
    // once in `new` and never mutated, so a lookup's answer never changes
    // after the first resolve. A `RefCell` (not the `Mutex` AST_CACHE uses),
    // since a `Runtime` is never shared across threads — this field is
    // per-instance, not a global static, on purpose: two `Runtime`s can load
    // the same domain name with different declared content (tests do), so a
    // global keyed only on name would leak one instance's answer into another's.
    resolved_cache: RefCell<HashMap<String, Arc<Map<String, Value>>>>,
}

const MAX_REACTION_DEPTH: usize = 5;

/// The trigger of the compensating leg. Not an event name — no aggregate
/// announces it — it is the procedure noticing that a leg it dispatched was
/// refused. Declared `on :refused` beside the ordinary legs, because the
/// compensation IS an ordinary leg; only its trigger differs.
const REFUSED: &str = "refused";

fn state_row((id, mut state): (String, State)) -> Value {
    state.insert("id".to_string(), Value::String(id));
    Value::Object(state)
}

fn boot_repository(
    aggregate: &crate::ir::Aggregate,
    bluebook_path: &str,
    persistence: crate::ports::persistence::Persistence,
) -> Result<Box<dyn PersistenceAdapter>, String> {
    let adapter = persistence.adapter.to_lowercase();
    if adapter == "memory" {
        return Err("Memory cannot be used as a mirror persistence adapter".to_string());
    }

    let mut options = persistence.settings.clone();
    for field in ["dir", "database"] {
        if let Some(path) = persistence.path(bluebook_path, field) {
            options.insert(field.to_string(), path.to_string_lossy().to_string());
        }
    }
    if let Some(database) = options.get("database").cloned() {
        options.insert("db".to_string(), database);
    }

    if adapter == "heki" {
        let dir = options.get("dir").ok_or_else(|| {
            format!(
                "{} binds Heki, which stores somewhere, but its world declares no \"dir\".",
                aggregate.name
            )
        })?;
        return Ok(Box::new(
            crate::adapters::driven::heki::HekiRepository::new(
                &aggregate.name,
                dir,
                aggregate.identified_by.clone(),
            )
            .map_err(|error| format!("cannot bind Heki at {dir} for {}: {error}", aggregate.name))?,
        ));
    }

    let factory = crate::ports::persistence::persistence_adapter::persistence_adapter_factory(&adapter)
        .ok_or_else(|| format!("cannot bind {} for {}: no host has registered that persistence adapter", persistence.adapter, aggregate.name))?;
    factory(
        &crate::ports::persistence::persistence_adapter::PersistenceSpec {
            aggregate: aggregate.clone(),
            options,
        },
    )
}

fn resolve_query_value(value: Option<&Value>, args: &State) -> Value {
    let Some(value) = value else {
        return Value::Null;
    };
    if let Some(name) = value.as_str().and_then(|s| s.strip_prefix(':')) {
        return args.get(name).cloned().unwrap_or(Value::Null);
    }
    value.clone()
}

// A literal where-value is stringified when the query is DECLARED
// (Rust's own parser and Ruby's QuerySpecification.render_value agree on
// this), indistinguishable on the wire from a String field's own value —
// `"5"` for the number 5, `"open"` for the string `"open"`. A kwarg
// reference resolves to whatever typed value the caller passed and never
// hits this path. Parsing the string here is safe precisely because a
// non-numeric string (a genuine text field) simply fails to parse and
// falls through to `None`, same as before.
fn query_number(value: &Value) -> Option<f64> {
    match value {
        Value::Number(_) => value.as_f64(),
        Value::String(text) => text.trim().parse::<f64>().ok(),
        Value::Object(fields) => {
            let numbers: Vec<f64> = fields.values().filter_map(query_number).collect();
            (numbers.len() == 1).then(|| numbers[0])
        }
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
        // Aggregate references are represented by their aggregate head's
        // identity state.  A one-field value is therefore usable at the
        // aggregate boundary without granting value objects independent IDs.
        Value::Object(fields) if fields.len() == 1 => fields
            .values()
            .next()
            .map(query_text)
            .unwrap_or_default(),
        other => other.to_string(),
    }
}

fn query_value(value: &Value) -> &Value {
    match value {
        Value::Object(fields) if fields.len() == 1 => {
            fields.values().next().map(query_value).unwrap_or(value)
        }
        _ => value,
    }
}

fn query_less_than(held: &Value, want: &Value) -> bool {
    match (query_number(held), query_number(want)) {
        (Some(h), Some(w)) => h < w,
        _ => false,
    }
}

fn query_greater_than(held: &Value, want: &Value) -> bool {
    match (query_number(held), query_number(want)) {
        (Some(h), Some(w)) => h > w,
        _ => false,
    }
}

fn query_at_least(held: &Value, want: &Value) -> bool {
    match (query_number(held), query_number(want)) {
        (Some(h), Some(w)) => h >= w,
        _ => false,
    }
}

fn query_at_most(held: &Value, want: &Value) -> bool {
    match (query_number(held), query_number(want)) {
        (Some(h), Some(w)) => h <= w,
        _ => false,
    }
}

// in/contains both read a comma-separated list — a real JSON array is read
// element by element (query_text already unwraps a single-field object, so
// a list of value objects works the same as a list of scalars) ; anything
// else is treated as CSV text, matching the convention Ruby's
// QueryInterpreter/Ports::Query::InMemory and the SQLite adapter both use.
fn query_members(value: &Value) -> Vec<String> {
    match value {
        Value::Array(items) => items.iter().map(query_text).collect(),
        _ => query_text(value)
            .split(',')
            .map(|part| part.trim().to_string())
            .filter(|part| !part.is_empty())
            .collect(),
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
    let field = lifecycle
        .get("field")
        .and_then(Value::as_str)
        .unwrap_or_default();
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
    let admitted = transitions.iter().find(|t| match t.get("from_state") {
        None | Some(Value::Null) => true,
        Some(from) => from.as_str() == Some(current.as_str()),
    });
    if let Some(t) = admitted {
        let to = t
            .get("to_state")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string();
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
            mirrors: BTreeMap::new(),
            events: Vec::new(),
            reactions: Vec::new(),
            sagas: Vec::new(),
            saga_instances: BTreeMap::new(),
            reaction_depth: 0,
            dispatch_trace: None,
            resolved_cache: RefCell::new(HashMap::new()),
        }
    }

    fn trace_step(&mut self, name: &'static str) {
        if let Some(trace) = &mut self.dispatch_trace {
            trace.push(name);
        }
    }

    /// Load one native Bluebook and attach the persistence declared by its
    /// neighbouring world and hecksagon files. Hosts register impure adapter
    /// factories (for example Sqlite) before booting; Memory and Heki are
    /// available in the core runtime itself.
    pub fn boot(bluebook_path: impl AsRef<std::path::Path>) -> Result<Self, String> {
        let bluebook_path = bluebook_path.as_ref();
        if bluebook_path
            .extension()
            .and_then(|extension| extension.to_str())
            != Some("bluebook")
        {
            return Err(format!(
                "{} is not a .bluebook — this runtime parses the native format",
                bluebook_path.display()
            ));
        }
        let source = fs::read_to_string(bluebook_path)
            .map_err(|error| format!("cannot read {}: {error}", bluebook_path.display()))?;
        let domain = crate::bluebook::parser::parse(&source);
        let mut runtime = Self::new(crate::projector::ir_json::domain_to_value(&domain));
        let source_text = bluebook_path.to_string_lossy();

        for aggregate in &domain.aggregates {
            let bindings = crate::ports::persistence::resolve_all_for(&source_text, &aggregate.name)?;
            if bindings.authoritative.adapter.to_lowercase() != "memory" {
                let repository = boot_repository(aggregate, &source_text, bindings.authoritative)?;
                runtime.attach(&aggregate.name, repository);
            }
            for mirror in bindings.mirrors {
                let name = mirror.adapter.clone();
                runtime.attach_mirror(&aggregate.name, name, boot_repository(aggregate, &source_text, mirror)?);
            }
            runtime.recover_mirrors(&aggregate.name)?;
        }

        Ok(runtime)
    }

    pub fn attach(&mut self, aggregate: &str, adapter: Box<dyn PersistenceAdapter>) {
        self.adapters.insert(aggregate.to_string(), adapter);
    }

    pub fn attach_mirror(&mut self, aggregate: &str, name: String, adapter: Box<dyn PersistenceAdapter>) {
        self.mirrors.entry(aggregate.to_string()).or_default().push((name, adapter));
    }

    fn recover_mirrors(&mut self, aggregate: &str) -> Result<(), String> {
        let entries = self.adapters.get(aggregate)
            .map(|adapter| adapter.replication_entries())
            .transpose()?
            .unwrap_or_default();
        let Some(mirrors) = self.mirrors.get_mut(aggregate) else { return Ok(()) };
        for (name, mirror) in mirrors {
            let expected: Vec<_> = entries.iter().filter(|entry| entry.mirrors.iter().any(|target| target.eq_ignore_ascii_case(name))).collect();
            let present = mirror.replication_entries()?;
            if present.len() > expected.len() || !present.iter().zip(&expected).all(|(left, right)| {
                left.operation == right.operation && left.id == right.id && left.state.as_ref().map(|state| &state.fields) == right.state.as_ref().map(|state| &state.fields)
            }) {
                return Err(format!("{aggregate} mirror {name} history does not match its authoritative history"));
            }
            for entry in expected.into_iter().skip(present.len()) {
                match (&entry.operation[..], &entry.state) {
                    ("save", Some(state)) => mirror.save(state.clone(), WriteContext::OutOfBand { reason: "mirror recovery" })?,
                    ("delete", _) => mirror.delete(&entry.id, WriteContext::OutOfBand { reason: "mirror recovery" })?,
                    _ => return Err(format!("{aggregate} has an invalid replication entry")),
                }
            }
        }
        Ok(())
    }

    fn save_with_mirrors(
        &mut self,
        aggregate: &str,
        state: crate::runtime::AggregateState,
        context: WriteContext<'_>,
    ) -> Result<(), String> {
        let mirror_names = self.mirrors.get(aggregate).map(|mirrors| mirrors.iter().map(|(name, _)| name.clone()).collect()).unwrap_or_default();
        if let Some(adapter) = self.adapters.get_mut(aggregate) {
            adapter.save_with_mirrors(state.clone(), mirror_names, context)
                .map_err(|error| format!("{aggregate} authoritative write failed: {error}"))?;
        }
        if let Some(mirrors) = self.mirrors.get_mut(aggregate) {
            for (_, mirror) in mirrors.iter_mut() {
                mirror.save(state.clone(), context)
                    .map_err(|error| format!("{aggregate} mirror write failed: {error}; replication intent remains durable"))?;
            }
        }
        Ok(())
    }

    pub fn aggregates(&self) -> Vec<(String, Map<String, Value>)> {
        let mut found = vec![];
        for domain in self.ir.as_object().cloned().unwrap_or_default().values() {
            for aggregate in domain
                .get("aggregates")
                .and_then(Value::as_array)
                .cloned()
                .unwrap_or_default()
            {
                if let Some(object) = aggregate.as_object() {
                    let name = object
                        .get("name")
                        .and_then(Value::as_str)
                        .unwrap_or_default();
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
            for aggregate in domain
                .get("aggregates")
                .and_then(Value::as_array)
                .cloned()
                .unwrap_or_default()
            {
                let Some(aggregate) = aggregate.as_object() else {
                    continue;
                };
                let name = aggregate
                    .get("name")
                    .and_then(Value::as_str)
                    .unwrap_or_default();

                let Some(adapter) = self.adapters.get(name) else {
                    continue;
                };
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
        let entity = self.find_entity(domain, aggregate_name, &aggregate, entity_name)?;
        let command =
            self.find_entity_command(domain, aggregate_name, entity_name, &entity, command_name)?;
        let normalized_args = normalize_command_args(&aggregate, &command, args)?;
        self.trace_step("normalize_args");
        // An entity command can declare a reference-typed attribute the same
        // way an aggregate command can (CommandRules#resolve_references is
        // shared by both interpreters on the Ruby side too), even though
        // nothing in the real corpus does yet. Part of Vocabulary::EntityDispatchOrder.
        self.resolve_references(domain, &command, &normalized_args)?;
        self.trace_step("resolve_references");
        let args = &normalized_args;

        let identity = aggregate
            .get("identified_by")
            .and_then(Value::as_str)
            .unwrap_or("id")
            .to_string();
        // The parent's identity is a PATH too : the caller passes the head and
        // the field is dug out, exactly as an aggregate command resolves it.
        let (parent_head, parent_field) = match identity.split_once('.') {
            Some((left, right)) => (left.to_string(), Some(right.to_string())),
            None => (identity.clone(), None),
        };
        let parent_id = args
            .get(&parent_head)
            .or_else(|| args.get("id"))
            .map(|value| match &parent_field {
                Some(name) => value
                    .get(name)
                    .map(query_text)
                    .unwrap_or_else(|| query_text(value)),
                None => query_text(value),
            })
            .filter(|id| !id.is_empty())
            .ok_or_else(|| {
                format!(
                    "{command_name} acts on a {aggregate_name}'s {entity_name} — pass {parent_head}:"
                )
            })?;

        let mut state = if let Some(adapter) = self.adapters.get(aggregate_name) {
            adapter
                .find(&parent_id)
                .map(value_bridge::from_state)
                .ok_or_else(|| format!("no {} with {} {:?}", aggregate_name, parent_head, parent_id))?
        } else {
            let key = format!("{}::{}#{}", domain, aggregate_name, parent_id);
            self.store
                .get(&key)
                .cloned()
                .ok_or_else(|| format!("no {} with {} {:?}", aggregate_name, parent_head, parent_id))?
        };
        self.trace_step("hydrate_parent");

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
        let want = args.get(&entity_key).cloned().ok_or_else(|| {
            format!("{command_name} acts on one {entity_name} — pass {entity_key}:")
        })?;
        // An entity's identity is a declared attribute like any other, so it is
        // coerced through its own type BEFORE it is matched — EntityInterpreter
        // #element_of has always done this. Matching the raw argument instead
        // meant a LedgerSequence of 0 was reported as a missing element rather
        // than as the invariant it actually violates, so the two runtimes
        // refused the same dispatch for different reasons. It also makes a
        // scalar stand in for a single-field value object here, the way it
        // does everywhere else. Part of Vocabulary::EntityDispatchOrder's
        // locate_element.
        let want = match array(&entity, "attributes")
            .into_iter()
            .filter_map(|held| held.as_object().cloned())
            .find(|held| held.get("name").and_then(Value::as_str) == Some(entity_key.as_str()))
        {
            Some(attribute) => coerce_attribute(&aggregate, &attribute, &want)?,
            None => want,
        };

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
        let mut element = elements[position].as_object().cloned().unwrap_or_default();
        self.trace_step("locate_element");

        for given in array(&command, "givens") {
            let canonical = given.get("canonical").and_then(Value::as_str).unwrap_or("");
            if !evaluate_given(canonical, &element, args)? {
                let description = given
                    .get("description")
                    .and_then(Value::as_str)
                    .unwrap_or("");
                return Err(format!("{} refused — {}", command_name, description));
            }
        }
        self.trace_step("enforce_givens");
        let transition_to = admissible_transition(&entity, command_name, &element)?;
        self.trace_step("admissible_transition");

        for mutation in array(&command, "mutations") {
            let target = mutation
                .get("target")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string();
            match mutation.get("op").and_then(Value::as_str) {
                Some("increment") | Some("decrement") => {
                    let operation = mutation
                        .get("op")
                        .and_then(Value::as_str)
                        .unwrap_or("increment");
                    let updated = arithmetic(&aggregate, &element, &target, operation, &mutation, args)?;
                    element.insert(target, updated);
                }
                _ => {
                    let value = resolve_source(&mutation, args);
                    let coerced = array(&entity, "attributes")
                        .into_iter()
                        .find(|attribute| {
                            attribute.get("name").and_then(Value::as_str) == Some(target.as_str())
                        })
                        .and_then(|attribute| attribute.as_object().cloned())
                        .map(|attribute| coerce_attribute(&aggregate, &attribute, &value))
                        .transpose()?
                        .unwrap_or(value);
                    element.insert(target, coerced);
                }
            }
        }
        self.trace_step("apply_mutations");
        if let Some((field, to_state)) = transition_to {
            element.insert(field, Value::String(to_state));
            self.trace_step("advance_lifecycle");
        }

        elements[position] = Value::Object(element);
        state.insert(list_attr, Value::Array(elements));

        if self.adapters.contains_key(aggregate_name) {
            self.save_with_mirrors(
                aggregate_name,
                value_bridge::to_state(&parent_id, &state),
                WriteContext::Dispatch {
                    aggregate: aggregate_name,
                    command: command_name,
                },
            )?;
        } else {
            let key = format!("{}::{}#{}", domain, aggregate_name, parent_id);
            self.store.insert(key, state.clone());
        }
        self.trace_step("save");

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
        self.trace_step("emit");

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
        if let Some((domain, query_name)) = verb.split_once('.') {
            if !domain.contains("::") {
                return self.query_read_model(domain, query_name, args);
            }
        }
        let (domain, aggregate_name, query_name) = parse_verb(verb)?;
        let aggregate = self.find_aggregate(&domain, &aggregate_name, verb)?;
        if query_name.contains('.') {
            return self.query_entity(&domain, &aggregate_name, &aggregate, &query_name, args);
        }
        let declared = self.find_query(&domain, &aggregate_name, &aggregate, &query_name)?;

        // A query's arguments are coerced against their declared types exactly as
        // a command's are — mirrors Ruby's QueryInterpreter#normalize_args. Without
        // this a query took whatever it was handed : Ruby refused
        // `cents: "lots"` for a Money and Rust answered with an empty result set,
        // agreeing about nothing. Reads enter through the aggregate, so they meet
        // the same gate writes do.
        let mut args = args.clone();
        for attribute in array(&declared, "attributes") {
            let Some(name) = attribute.get("name").and_then(Value::as_str) else {
                continue;
            };
            let Some(given) = args.get(name).cloned() else {
                continue;
            };
            let attribute = attribute.as_object().cloned().unwrap_or_default();
            let coerced = coerce_attribute(&aggregate, &attribute, &given)?;
            args.insert(name.to_string(), coerced);
        }
        let args = &args;

        let wheres = array(&declared, "wheres");
        let mut matched: Vec<(String, State)> = Vec::new();
        for (key, state) in self.all_records(&domain, &aggregate_name, &aggregate) {
            let holds = wheres.iter().all(|clause| {
                let field = clause
                    .get("field")
                    .and_then(Value::as_str)
                    .unwrap_or_default();
                let held = state.get(field).cloned().unwrap_or(Value::Null);
                let want = resolve_query_value(clause.get("value"), args);
                match clause.get("op").and_then(Value::as_str) {
                    Some("ne") => query_value(&held) != query_value(&want),
                    Some("lt") => query_less_than(&held, &want),
                    Some("lte") => query_at_most(&held, &want),
                    Some("gt") => query_greater_than(&held, &want),
                    Some("gte") => query_at_least(&held, &want),
                    Some("in") => query_members(&want).contains(&query_text(&held)),
                    Some("contains") => query_members(&held).contains(&query_text(&want)),
                    _ => query_value(&held) == query_value(&want),
                }
            });
            if holds {
                matched.push((key, state));
            }
        }

        // THE TWO TIERS THE PORT DECLARES — see Ports::Query::Ordering. The declared
        // order when there is one, then IDENTITY, always. Identity is the base rather
        // than only a tiebreak because an ask with no order_by used to hand back
        // whatever order the store held, which is how a heki-backed Ruby and a
        // heki-backed Rust came to answer the same ask differently. sort_by is stable
        // here, so the declared pass keeps this base underneath it.
        matched.sort_by(|(a_id, _), (b_id, _)| a_id.cmp(b_id));

        if let Some(order) = declared.get("order_by").and_then(Value::as_object) {
            let field = order
                .get("field")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string();
            matched.sort_by(|(a_id, a), (b_id, b)| {
                let left = a.get(&field).cloned().unwrap_or(Value::Null);
                let right = b.get(&field).cloned().unwrap_or(Value::Null);
                query_order(&left, &right).then_with(|| a_id.cmp(b_id))
            });
            if order.get("direction").and_then(Value::as_str) == Some("desc") {
                matched.reverse();
            }
        }

        let capped: Vec<(String, State)> = match declared.get("limit").and_then(|l| l.get("value"))
        {
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

    fn query_read_model(&mut self, domain: &str, query_name: &str, args: &State) -> Result<Vec<Value>, String> {
        let declared_domain = self.find_domain(domain)?;
        let model = array(&declared_domain, "read_models").into_iter()
            .find(|model| model.get("query_name").and_then(Value::as_str) == Some(query_name))
            .and_then(|model| model.as_object().cloned())
            .ok_or_else(|| format!("{domain} has no read model {query_name:?}"))?;
        let reference_name = model.get("reference_name").and_then(Value::as_str).unwrap_or("reference");
        let reference_id = args.get(reference_name).map(query_text).unwrap_or_default();
        let mut projected: Vec<(String, Vec<(String, State)>)> = Vec::new();
        let mut report = Map::new();
        for head in array(&model, "aggregate_heads") {
            let head = head.as_object().ok_or_else(|| "read model head must be an object".to_string())?;
            let aggregate_name = head.get("aggregate").and_then(Value::as_str).unwrap_or_default();
            let name = head.get("as").and_then(Value::as_str).unwrap_or_default().to_string();
            // find_aggregate is cache-backed, and this is the same aggregate
            // whether the row is the reference target or a projected source —
            // resolved once here and reused for both branches below (the
            // original called the equivalent lookup twice in the else branch).
            let aggregate = self.find_aggregate(domain, aggregate_name, query_name)?;
            let mut rows = self.all_records(domain, aggregate_name, &aggregate);
            if aggregate_name == model.get("reference_target").and_then(Value::as_str).unwrap_or_default() {
                rows.retain(|(id, _)| id == &reference_id);
                if rows.is_empty() { return Err(format!("no {aggregate_name} with reference {reference_id:?}")); }
            } else {
                rows.retain(|(_, state)| projected.iter().any(|(source_name, source_rows)| {
                    let reference_type = format!("Reference<{source_name}>");
                    let fields: Vec<String> = array(&aggregate, "attributes").into_iter()
                        .filter(|attribute| attribute.get("type").and_then(Value::as_str) == Some(reference_type.as_str()))
                        .filter_map(|attribute| attribute.get("name").and_then(Value::as_str).map(str::to_string))
                        .collect();
                    fields.iter().any(|field| source_rows.iter().any(|(id, _)| state.get(field).map(query_text).as_deref() == Some(id.as_str())))
                }));
            }
            rows.sort_by(|(left, _), (right, _)| left.cmp(right));
            let many = head.get("many").and_then(Value::as_bool).unwrap_or(false);
            report.insert(name.clone(), if many { Value::Array(rows.iter().cloned().map(state_row).collect()) } else { rows.first().cloned().map(state_row).unwrap_or(Value::Null) });
            projected.push((aggregate_name.to_string(), rows));
        }
        Ok(vec![Value::Object(report)])
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
        let entity = self.find_entity(domain, aggregate_name, aggregate, entity_name)?;
        let declared =
            self.find_entity_query(domain, aggregate_name, entity_name, &entity, query_name)?;
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
        let wheres = array(&declared, "wheres");
        let mut rows: Vec<Value> = Vec::new();
        for (parent_id, state) in self.all_records(domain, aggregate_name, aggregate) {
            for element in state
                .get(&list_attr)
                .and_then(Value::as_array)
                .cloned()
                .unwrap_or_default()
            {
                let Some(element) = element.as_object() else {
                    continue;
                };
                let holds = wheres.iter().all(|clause| {
                    let field = clause
                        .get("field")
                        .and_then(Value::as_str)
                        .unwrap_or_default();
                    let held = element.get(field).cloned().unwrap_or(Value::Null);
                    let want = resolve_query_value(clause.get("value"), args);
                    match clause.get("op").and_then(Value::as_str) {
                        Some("ne") => query_value(&held) != query_value(&want),
                        Some("lt") => query_less_than(&held, &want),
                        Some("lte") => query_at_most(&held, &want),
                        Some("gt") => query_greater_than(&held, &want),
                        Some("gte") => query_at_least(&held, &want),
                        Some("in") => query_members(&want).contains(&query_text(&held)),
                        Some("contains") => query_members(&held).contains(&query_text(&want)),
                        _ => query_value(&held) == query_value(&want),
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

        // THE SAME TWO TIERS, one level down — see Ports::Query::Ordering. A
        // sub-list row is identified by its PARENT and then by the entity's own
        // key, since two entities under different parents can share a sequence,
        // and a parent alone would leave every sibling tied.
        let entity_key = entity
            .get("identified_by")
            .and_then(Value::as_str)
            .unwrap_or("id")
            .to_string();
        rows.sort_by(|a, b| {
            let left_parent = query_text(a.get(&parent_key).unwrap_or(&Value::Null));
            let right_parent = query_text(b.get(&parent_key).unwrap_or(&Value::Null));
            left_parent.cmp(&right_parent).then_with(|| {
                let left = a.get(&entity_key).cloned().unwrap_or(Value::Null);
                let right = b.get(&entity_key).cloned().unwrap_or(Value::Null);
                query_order(&left, &right)
            })
        });

        if let Some(order) = declared.get("order_by").and_then(Value::as_object) {
            let field = order
                .get("field")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string();
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

    /// A reference must point at something that EXISTS.
    ///
    /// Mirrors Ruby's `CommandInterpreter#resolve_references`. `reference_to
    /// Customer` is the one guarantee an aggregate reference is for, and it was
    /// declared 14 times across banking and enforced in neither runtime — an
    /// Account could belong to a customer who was never registered, and parity
    /// stayed green because both sides were equally permissive.
    ///
    /// Checked here, not in coercion, because coercion holds no store. A
    /// reference INTO ANOTHER DOMAIN is left alone : the target may legitimately
    /// not be loaded, the same reading `across` policies already get.
    fn resolve_references(
        &mut self,
        domain: &str,
        command: &Map<String, Value>,
        args: &State,
    ) -> Result<(), String> {
        for attribute in array(command, "attributes") {
            let Some(name) = attribute.get("name").and_then(Value::as_str) else {
                continue;
            };
            let Some(type_name) = attribute.get("type").and_then(Value::as_str) else {
                continue;
            };
            let Some(target_name) = type_name
                .strip_prefix("Reference<")
                .and_then(|rest| rest.strip_suffix('>'))
            else {
                continue;
            };
            let Some(held) = args.get(name) else { continue };
            if held.is_null() {
                continue;
            }
            let Ok(target) = self.find_aggregate(domain, target_name, name) else {
                continue;
            };
            let key = match held {
                Value::Object(fields) if fields.len() == 1 => fields
                    .values()
                    .next()
                    .map(query_text)
                    .unwrap_or_default(),
                other => query_text(other),
            };
            if key.is_empty() {
                continue;
            }
            // The HEAD names what a caller passes, so it is what a refusal names.
            let identity = target
                .get("identified_by")
                .and_then(Value::as_str)
                .unwrap_or("id")
                .split('.')
                .next()
                .unwrap_or("id")
                .to_string();
            let found = self
                .all_records(domain, target_name, &target)
                .into_iter()
                .any(|(id, _)| id == key);
            if !found {
                return Err(format!("no {target_name} with {identity} {key:?}"));
            }
        }
        Ok(())
    }

    pub fn dispatch(&mut self, verb: &str, args: &State) -> Result<State, String> {
        let (domain, aggregate_name, command_name) = parse_verb(verb)?;
        if command_name.contains('.') {
            return self.dispatch_entity(&domain, &aggregate_name, &command_name, args);
        }
        let aggregate = self.find_aggregate(&domain, &aggregate_name, verb)?;
        let command = self
            .find_command(&domain, &aggregate_name, &aggregate, &command_name)
            .ok_or_else(|| format!("{} has no command {:?}", aggregate_name, command_name))?;
        refuse_unknown_arguments(&aggregate, &command, args, &self.correlation_keys(&domain))?;
        self.trace_step("refuse_unknown_arguments");
        let normalized_args = normalize_command_args(&aggregate, &command, args)?;
        self.trace_step("normalize_args");
        self.resolve_references(&domain, &command, &normalized_args)?;
        self.trace_step("resolve_references");
        let args = &normalized_args;

        let identity = aggregate
            .get("identified_by")
            .and_then(Value::as_str)
            .unwrap_or("id")
            .to_string();
        let creates = command
            .get("references")
            .map(Value::is_null)
            .unwrap_or(true);

        let (id, mut state) = self.hydrate(&aggregate, &command, args, &identity, creates)?;
        self.trace_step("hydrate");

        for given in array(&command, "givens") {
            let canonical = given.get("canonical").and_then(Value::as_str).unwrap_or("");
            if !evaluate_given(canonical, &state, args)? {
                let description = given
                    .get("description")
                    .and_then(Value::as_str)
                    .unwrap_or("");
                return Err(format!("{} refused — {}", command_name, description));
            }
        }
        self.trace_step("enforce_givens");

        let transition_to = admissible_transition(&aggregate, &command_name, &state)?;
        self.trace_step("admissible_transition");

        if creates {
            assign_creation_attributes(&mut state, &aggregate, &command, args)?;
            self.trace_step("assign_creation_attributes");
        }
        for mutation in array(&command, "mutations") {
            apply_mutation(&mut state, &aggregate, &mutation, args)?;
        }
        self.trace_step("apply_mutations");
        if let Some((field, to_state)) = transition_to {
            state.insert(field, Value::String(to_state));
            self.trace_step("advance_lifecycle");
        }

        if self.adapters.contains_key(&aggregate_name) {
            self.save_with_mirrors(
                &aggregate_name,
                value_bridge::to_state(&id, &state),
                WriteContext::Dispatch {
                    aggregate: &aggregate_name,
                    command: &command_name,
                },
            )?;
        } else {
            let key = format!("{}::{}#{}", domain, aggregate_name, id);
            self.store.insert(key, state.clone());
        }
        self.trace_step("save");

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
        self.trace_step("emit");

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
        let aggregate_name = aggregate
            .get("name")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string();
        let command_name = command
            .get("name")
            .and_then(Value::as_str)
            .unwrap_or("command");

        // NOTHING IS MINTED. An invented identity is neither derived from the
        // record nor permanently associated with it — this counted, Ruby drew a
        // random hex, and the same dispatch made two different records. A
        // creating command that cannot say WHICH ONE THIS IS is refused, and an
        // aggregate with no `identified_by` has to be told.
        // A PATH names the field carrying the id : the caller passes the HEAD and
        // the field is dug out, because an id is always a scalar.
        let (head, field) = match identity.split_once(char::from(46)) {
            Some((left, right)) => (left, Some(right)),
            None => (identity, None),
        };
        let dig = |value: &Value| -> String {
            match field {
                Some(name) => value.get(name).map(query_text).unwrap_or_else(|| query_text(value)),
                None => query_text(value),
            }
        };

        if creates {
            let id = args
                .get(head)
                .filter(|value| query_truthy(value))
                .map(&dig)
                .ok_or_else(|| {
                    format!("{command_name} creates a {aggregate_name} — pass {head}:")
                })?;
            return Ok((id, defaults_for(aggregate)?));
        }

        let reference_key = command
            .get("references")
            .and_then(Value::as_str)
            .map(crate::naming::reference_key)
            .unwrap_or_default();
        // Aggregate identity is represented by the identity value object's
        // fields.  Validate it even when the command did not declare that
        // field as payload, matching the Ruby dispatcher before it unwraps
        // the identity for lookup.
        if let Some(value) = args.get(identity) {
            if let Some(attribute) = array(aggregate, "attributes")
                .iter()
                .find(|attribute| attribute.get("name").and_then(Value::as_str) == Some(identity))
                .and_then(Value::as_object)
            {
                coerce_attribute(aggregate, attribute, value)?;
            }
        }
        let mut identity_keys = vec![head];
        if identity == "id" {
            identity_keys.push("id");
        }
        if !reference_key.is_empty() {
            identity_keys.push(reference_key.as_str());
        }
        let id = identity_keys.into_iter()
            .filter_map(|key| args.get(key))
            .map(&dig)
            .find(|value| !value.is_empty())
            .ok_or_else(|| {
                format!(
                    "{} acts on an existing {} — pass {}:",
                    command_name, aggregate_name, head
                )
            })?;

        if let Some(adapter) = self.adapters.get(&aggregate_name) {
            let state = adapter
                .find(&id)
                .map(value_bridge::from_state)
                .ok_or_else(|| format!("no {} with {} {:?}", aggregate_name, head, id))?;
            return Ok((id, state));
        }

        let key = self
            .store
            .keys()
            .find(|key| key.ends_with(&format!("::{}#{}", aggregate_name, id)))
            .cloned()
            .ok_or_else(|| format!("no {} with {} {:?}", aggregate_name, head, id))?;

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
                let text = value
                    .as_str()
                    .map(str::to_string)
                    .unwrap_or_else(|| value.to_string());
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
        if id.is_empty() {
            None
        } else {
            Some(id.to_string())
        }
    }

    fn begin_saga(&mut self, pm: &Value, event: &Value) {
        let name = pm
            .get("name")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string();
        let event_name = event
            .get("name")
            .and_then(Value::as_str)
            .unwrap_or_default();
        if Some(event_name) != pm.get("starts_on").and_then(Value::as_str) {
            return;
        }

        let Some(correlation) = Self::correlation(pm, event) else {
            let field = pm
                .get("correlates_by")
                .and_then(Value::as_str)
                .unwrap_or_default();
            self.sagas.push(json!({
                "process_manager": name, "on": event_name,
                "born": false, "reason": format!("no {field} in the payload"),
            }));
            return;
        };
        if self
            .saga_instances
            .get(&name)
            .is_some_and(|t| t.contains_key(&correlation))
        {
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
        let pm_name = pm
            .get("name")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string();
        let event_name = event
            .get("name")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string();
        let Some(handler) = pm
            .get("handlers")
            .and_then(Value::as_array)
            .and_then(|hs| {
                hs.iter().find(|h| {
                    h.get("event_type").and_then(Value::as_str) == Some(event_name.as_str())
                })
            })
            .cloned()
        else {
            return;
        };
        let Some(correlation) = Self::correlation(pm, event) else {
            return;
        };

        let from = handler
            .get("from_state")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string();
        let to = handler
            .get("to_state")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string();

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
        let command = spec
            .get("command_name")
            .and_then(Value::as_str)
            .unwrap_or_default();
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
        for pair in spec
            .get("with")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default()
        {
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
                None => ruby_literal_value(token),
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
        let refused = match outcome {
            Ok(()) => {
                entry.insert("delivered".into(), Value::Bool(true));
                false
            }
            Err(reason) => {
                entry.insert("delivered".into(), Value::Bool(false));
                entry.insert("reason".into(), Value::String(reason));
                true
            }
        };
        self.sagas.push(record);

        if refused {
            self.unwind_saga(pm_name, event, memory, correlation, domain);
        }
    }

    /// A refused leg UNWINDS — the procedure runs the leg declared `on :refused`,
    /// which is where the compensation lives.
    ///
    /// Until this existed a refusal was RECORDED and nothing else happened.
    /// Banking's settlement into a frozen destination left the debit standing with
    /// no credit and no reversal, and the corpus hand-drove the transfer to
    /// `settled` — money taken from the source, never delivered, and called done.
    ///
    /// A compensation that is itself refused does not unwind again, and needs no
    /// flag: the state moves to the compensating leg's `to_state` BEFORE its
    /// dispatches run, so a second refusal finds the instance no longer in
    /// `from_state` and records that instead. The check is the guard.
    fn unwind_saga(
        &mut self,
        pm_name: &str,
        event: &Value,
        memory: &Map<String, Value>,
        correlation: &str,
        domain: &str,
    ) {
        let Some(handler) = self
            .ir
            .get(domain)
            .and_then(|b| b.get("process_managers"))
            .and_then(Value::as_array)
            .and_then(|pms| {
                pms.iter()
                    .find(|p| p.get("name").and_then(Value::as_str) == Some(pm_name))
            })
            .and_then(|p| p.get("handlers"))
            .and_then(Value::as_array)
            .and_then(|handlers| {
                handlers
                    .iter()
                    .find(|h| h.get("event_type").and_then(Value::as_str) == Some(REFUSED))
            })
            .cloned()
        else {
            return;
        };

        let from = handler
            .get("from_state")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string();
        let to = handler
            .get("to_state")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string();
        let state = self
            .saga_instances
            .get(pm_name)
            .and_then(|table| table.get(correlation))
            .map(|instance| instance.0.clone())
            .unwrap_or_default();

        if state != from {
            self.sagas.push(json!({
                "process_manager": pm_name, "on": REFUSED, "instance": correlation,
                "advanced": false, "reason": format!("in {state:?}, not {from:?}"),
            }));
            return;
        }

        if let Some(instance) = self
            .saga_instances
            .get_mut(pm_name)
            .and_then(|table| table.get_mut(correlation))
        {
            instance.0 = to.clone();
        }
        self.sagas.push(json!({
            "process_manager": pm_name, "on": REFUSED, "instance": correlation,
            "advanced": true, "from": from, "to": to,
        }));

        let dispatches = handler
            .get("dispatches")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
        for spec in &dispatches {
            self.deliver_saga_dispatch(pm_name, spec, event, memory, correlation, domain);
        }
    }

    fn end_saga(&mut self, pm: &Value, event: &Value) {
        let name = pm
            .get("name")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string();
        let event_name = event
            .get("name")
            .and_then(Value::as_str)
            .unwrap_or_default();
        if Some(event_name) != pm.get("ends_on").and_then(Value::as_str) {
            return;
        }
        let Some(correlation) = Self::correlation(pm, event) else {
            return;
        };
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
                    policy
                        .get("name")
                        .and_then(Value::as_str)
                        .unwrap_or_default()
                        .to_string(),
                    format!("{target_domain}::{trigger}"),
                ))
            })
            .collect()
    }

    /// What a process manager correlates by is ROUTING, not description. A saga
    /// threads its correlation key through every leg it dispatches so the event
    /// each leg emits carries it and the next step can be correlated — so the key
    /// arrives on commands that never declare it, and legitimately.
    fn correlation_keys(&self, domain: &str) -> Vec<String> {
        self.ir
            .get(domain)
            .and_then(|bluebook| bluebook.get("process_managers"))
            .and_then(Value::as_array)
            .map(|sagas| {
                sagas
                    .iter()
                    .filter_map(|saga| saga.get("correlates_by").and_then(Value::as_str))
                    .map(str::to_string)
                    .collect()
            })
            .unwrap_or_default()
    }

    // Every resolved subtree below is a pure function of (ir, key) — ir is set
    // once in `new` and never mutated after — so the first resolve's answer is
    // final. Only successful resolutions are cached (the `?` on `resolve()?`
    // propagates before the insert): a failed lookup is an error path, not the
    // hot path, so it stays a cheap re-scan rather than needing an Option-typed
    // cache entry. The RefCell borrow is dropped before `resolve` runs, so a
    // resolver that itself resolves another cached key can't double-borrow.
    fn cached_lookup(
        &self,
        key: String,
        resolve: impl FnOnce() -> Result<Map<String, Value>, String>,
    ) -> Result<Arc<Map<String, Value>>, String> {
        if let Some(hit) = self.resolved_cache.borrow().get(&key) {
            return Ok(hit.clone());
        }
        let resolved = Arc::new(resolve()?);
        self.resolved_cache.borrow_mut().insert(key, resolved.clone());
        Ok(resolved)
    }

    fn find_domain(&self, domain: &str) -> Result<Arc<Map<String, Value>>, String> {
        self.cached_lookup(format!("domain:{domain}"), || {
            self.ir
                .get(domain)
                .and_then(Value::as_object)
                .cloned()
                .ok_or_else(|| format!("no domain {domain:?} loaded"))
        })
    }

    fn find_aggregate(
        &self,
        domain: &str,
        name: &str,
        verb: &str,
    ) -> Result<Arc<Map<String, Value>>, String> {
        self.cached_lookup(format!("aggregate:{domain}:{name}"), || {
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
        })
    }

    fn find_entity(
        &self,
        domain: &str,
        aggregate_name: &str,
        aggregate: &Map<String, Value>,
        entity_name: &str,
    ) -> Result<Arc<Map<String, Value>>, String> {
        self.cached_lookup(
            format!("entity:{domain}:{aggregate_name}:{entity_name}"),
            || {
                array(aggregate, "entities")
                    .into_iter()
                    .find(|e| e.get("name").and_then(Value::as_str) == Some(entity_name))
                    .and_then(|e| e.as_object().cloned())
                    .ok_or_else(|| format!("{} has no entity {:?}", aggregate_name, entity_name))
            },
        )
    }

    fn find_command(
        &self,
        domain: &str,
        aggregate_name: &str,
        aggregate: &Map<String, Value>,
        name: &str,
    ) -> Option<Arc<Map<String, Value>>> {
        self.cached_lookup(format!("command:{domain}:{aggregate_name}:{name}"), || {
            array(aggregate, "commands")
                .into_iter()
                .find(|c| c.get("name").and_then(Value::as_str) == Some(name))
                .and_then(|c| c.as_object().cloned())
                .ok_or_else(String::new)
        })
        .ok()
    }

    fn find_entity_command(
        &self,
        domain: &str,
        aggregate_name: &str,
        entity_name: &str,
        entity: &Map<String, Value>,
        command_name: &str,
    ) -> Result<Arc<Map<String, Value>>, String> {
        self.cached_lookup(
            format!("entity_command:{domain}:{aggregate_name}:{entity_name}:{command_name}"),
            || {
                array(entity, "commands")
                    .into_iter()
                    .find(|c| c.get("name").and_then(Value::as_str) == Some(command_name))
                    .and_then(|c| c.as_object().cloned())
                    .ok_or_else(|| format!("{} has no command {:?}", entity_name, command_name))
            },
        )
    }

    fn find_query(
        &self,
        domain: &str,
        aggregate_name: &str,
        aggregate: &Map<String, Value>,
        query_name: &str,
    ) -> Result<Arc<Map<String, Value>>, String> {
        self.cached_lookup(
            format!("query:{domain}:{aggregate_name}:{query_name}"),
            || {
                array(aggregate, "queries")
                    .into_iter()
                    .find(|q| q.get("name").and_then(Value::as_str) == Some(query_name))
                    .and_then(|q| q.as_object().cloned())
                    .ok_or_else(|| format!("{} has no query {:?}", aggregate_name, query_name))
            },
        )
    }

    fn find_entity_query(
        &self,
        domain: &str,
        aggregate_name: &str,
        entity_name: &str,
        entity: &Map<String, Value>,
        query_name: &str,
    ) -> Result<Arc<Map<String, Value>>, String> {
        self.cached_lookup(
            format!("entity_query:{domain}:{aggregate_name}:{entity_name}:{query_name}"),
            || {
                array(entity, "queries")
                    .into_iter()
                    .find(|q| q.get("name").and_then(Value::as_str) == Some(query_name))
                    .and_then(|q| q.as_object().cloned())
                    .ok_or_else(|| format!("{} has no query {:?}", entity_name, query_name))
            },
        )
    }
}

fn ruby_literal_value(token: &str) -> Value {
    let token = token.trim();
    if !token.starts_with('{') || !token.ends_with('}') {
        return Value::String(token.to_string());
    }

    let mut fields = Map::new();
    for pair in token[1..token.len() - 1].split(',') {
        let Some((key, value)) = pair.split_once("=>") else {
            continue;
        };
        let key = key.trim().trim_start_matches(':');
        let value = value.trim().trim_matches('"');
        fields.insert(key.to_string(), Value::String(value.to_string()));
    }
    Value::Object(fields)
}

fn parse_verb(verb: &str) -> Result<(String, String, String), String> {
    let (domain, aggregate, command) = crate::naming::split_verb(verb)
        .ok_or_else(|| format!("{:?} is not a fully-qualified verb", verb))?;

    Ok((
        domain.to_string(),
        aggregate.to_string(),
        command.to_string(),
    ))
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
    use crate::ports::persistence::ReplicationEntry;
    use crate::runtime::{AggregateState, PersistenceAdapter};
    use serde_json::json;
    use std::collections::HashMap;
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
        assert!(!query_less_than(&Value::Null, &json!(1)));
    }

    // A where-clause's literal value is stringified when the query is
    // declared — "5" for the number 5 — indistinguishable on the wire from a
    // String field's own value. `query_number` recovers the number FROM
    // either side, which is what makes a literal (not just a kwarg
    // reference) usable in gt/gte/lt/lte at all — this was the actual gap:
    // the corpus's only `lt` usage is a kwarg, so a literal number never
    // exercised this path before spec/fixtures/query_ops.bluebook existed.
    #[test]
    fn a_numeric_string_compares_as_the_number_it_spells() {
        assert!(query_less_than(&json!(1), &json!("2")));
        assert!(query_less_than(&json!("1"), &json!(2)));
        assert!(query_greater_than(&json!("10"), &json!(5)));
        assert!(query_at_least(&json!("5"), &json!(5)));
        assert!(query_at_most(&json!(5), &json!("5")));
    }

    #[test]
    fn every_ordering_operator_matches_its_declared_algebra() {
        assert!(query_greater_than(&json!(10), &json!(5)));
        assert!(!query_greater_than(&json!(5), &json!(10)));
        assert!(!query_greater_than(&json!(5), &json!(5)));

        assert!(query_at_least(&json!(10), &json!(5)));
        assert!(query_at_least(&json!(5), &json!(5)));
        assert!(!query_at_least(&json!(4), &json!(5)));

        assert!(query_at_most(&json!(5), &json!(10)));
        assert!(query_at_most(&json!(5), &json!(5)));
        assert!(!query_at_most(&json!(10), &json!(5)));

        // Non-numeric operands are silently false, never a panic — a
        // where-clause never raises the way a given does.
        assert!(!query_greater_than(&json!("a"), &json!("b")));
        assert!(!query_at_least(&Value::Null, &json!(1)));
    }

    #[test]
    fn members_reads_a_json_array_or_falls_back_to_csv_text() {
        assert_eq!(
            query_members(&json!(["a", "b"])),
            vec!["a".to_string(), "b".to_string()]
        );
        assert_eq!(
            query_members(&json!("a,b, c")),
            vec!["a".to_string(), "b".to_string(), "c".to_string()]
        );
        // A list of value objects unwraps the same way a scalar field does.
        assert_eq!(
            query_members(&json!([{"value": "urgent"}, {"value": "later"}])),
            vec!["urgent".to_string(), "later".to_string()]
        );
        assert_eq!(query_members(&Value::Null), Vec::<String>::new());
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

    struct JournalAdapter {
        records: HashMap<String, AggregateState>,
        entries: Vec<ReplicationEntry>,
    }

    impl JournalAdapter {
        fn empty() -> Self { Self { records: HashMap::new(), entries: vec![] } }
    }

    impl PersistenceAdapter for JournalAdapter {
        fn find(&self, id: &str) -> Option<&AggregateState> { self.records.get(id) }
        fn find_mut(&mut self, id: &str) -> Option<&mut AggregateState> { self.records.get_mut(id) }
        fn all(&self) -> Vec<&AggregateState> { self.records.values().collect() }
        fn count(&self) -> usize { self.records.len() }
        fn next_id_value(&self) -> u64 { 1 }
        fn id_for_command(&mut self, _attrs: &HashMap<String, crate::runtime::Value>) -> String { "1".to_string() }
        fn save(&mut self, state: AggregateState, _ctx: WriteContext<'_>) -> Result<(), String> {
            self.entries.push(ReplicationEntry { operation: "save".to_string(), id: state.id.clone(), state: Some(state.clone()), mirrors: vec![] });
            self.records.insert(state.id.clone(), state);
            Ok(())
        }
        fn delete(&mut self, id: &str, _ctx: WriteContext<'_>) -> Result<(), String> {
            self.entries.push(ReplicationEntry { operation: "delete".to_string(), id: id.to_string(), state: None, mirrors: vec![] });
            self.records.remove(id);
            Ok(())
        }
        fn replication_entries(&self) -> Result<Vec<ReplicationEntry>, String> { Ok(self.entries.clone()) }
        fn query(&self, _wheres: &[crate::ir::WhereClause], _attrs: &HashMap<String, String>) -> Option<Vec<AggregateState>> { None }
        fn seed_record(&mut self, state: AggregateState) { self.records.insert(state.id.clone(), state); }
        fn set_next_id(&mut self, _value: u64) {}
    }

    #[test]
    fn boot_repairs_a_mirror_that_missed_an_authoritative_append() {
        let mut state = AggregateState::new("a");
        state.set("balance", crate::runtime::Value::Int(500));
        let primary = JournalAdapter {
            records: HashMap::from([("a".to_string(), state.clone())]),
            entries: vec![ReplicationEntry { operation: "save".to_string(), id: "a".to_string(), state: Some(state), mirrors: vec!["Sqlite".to_string()] }],
        };
        let mut runtime = Runtime::new(json!({}));
        runtime.attach("Account", Box::new(primary));
        runtime.attach_mirror("Account", "Sqlite".to_string(), Box::new(JournalAdapter::empty()));

        runtime.recover_mirrors("Account").unwrap();

        let mirror = &runtime.mirrors["Account"][0].1;
        assert_eq!(mirror.find("a").unwrap().get("balance"), &crate::runtime::Value::Int(500));
    }
}

#[cfg(test)]
mod dispatch_order_tests {
    use super::*;

    // Mirrors spec/vocabulary_conformance_spec.rb's two trace specs — same
    // fixtures, same declared order (Vocabulary::AggregateDispatchOrder /
    // EntityDispatchOrder in language/bluebook.bluebook), proving Rust's
    // dispatch/dispatch_entity follow it too, not just Ruby's.
    #[test]
    fn aggregate_dispatch_matches_the_declared_order() {
        let mut runtime = Runtime::boot("../spec/fixtures/dispatch_order.bluebook").unwrap();
        runtime.dispatch_trace = Some(Vec::new());

        let args: State = serde_json::from_value(json!({
            "id": "w1",
            "label": {"value": "x"},
            "amount": {"value": 5},
            "part_sequence": {"value": 1},
            "part_note": {"value": "start"}
        }))
        .unwrap();

        runtime.dispatch("DispatchOrder::Widget.Open", &args).unwrap();

        let trace = runtime.dispatch_trace.take().unwrap();
        assert_eq!(
            trace,
            vec![
                "refuse_unknown_arguments",
                "normalize_args",
                "resolve_references",
                "hydrate",
                "enforce_givens",
                "admissible_transition",
                "assign_creation_attributes",
                "apply_mutations",
                "advance_lifecycle",
                "save",
                "emit",
            ]
        );
    }

    #[test]
    fn entity_dispatch_matches_the_declared_order() {
        // Not banking — that domain is really persisted (Heki/Sqlite, per its
        // own .world/.hecksagon), and Runtime::boot writes real files under
        // examples/banking/data/ with no in-memory override available on the
        // Rust side (unlike Ruby's InMemoryDomain::MEMORY_ADAPTER). This
        // fixture has no .world/.hecksagon sibling at all, so it defaults to
        // the in-memory store — same fixture the Ruby spec uses.
        let mut runtime = Runtime::boot("../spec/fixtures/dispatch_order.bluebook").unwrap();

        let open: State = serde_json::from_value(json!({
            "id": "w1",
            "label": {"value": "x"},
            "amount": {"value": 5},
            "part_sequence": {"value": 1},
            "part_note": {"value": "start"}
        }))
        .unwrap();
        runtime.dispatch("DispatchOrder::Widget.Open", &open).unwrap();

        runtime.dispatch_trace = Some(Vec::new());
        let advance: State = serde_json::from_value(json!({
            "id": "w1",
            "sequence": {"value": 1},
            "note": {"value": "done note"}
        }))
        .unwrap();
        runtime.dispatch("DispatchOrder::Widget.Part.Advance", &advance).unwrap();

        let trace = runtime.dispatch_trace.take().unwrap();
        assert_eq!(
            trace,
            vec![
                "normalize_args",
                "resolve_references",
                "hydrate_parent",
                "locate_element",
                "enforce_givens",
                "admissible_transition",
                "apply_mutations",
                "advance_lifecycle",
                "save",
                "emit",
            ]
        );
    }
}

#[cfg(test)]
mod resolved_cache_tests {
    use super::*;

    // Same shape as evaluator.rs's AST_CACHE identity check: proves
    // find_aggregate resolves the aggregate's declared shape once per
    // (domain, name) and reuses it — not once per dispatch — which is the
    // whole point of caching it instead of re-cloning the aggregate subtree
    // on every call.
    #[test]
    fn dispatching_twice_reuses_the_same_resolved_aggregate() {
        let mut runtime = Runtime::boot("../spec/fixtures/dispatch_order.bluebook").unwrap();

        let open: State = serde_json::from_value(json!({
            "id": "w1",
            "label": {"value": "x"},
            "amount": {"value": 5},
            "part_sequence": {"value": 1},
            "part_note": {"value": "start"}
        }))
        .unwrap();
        runtime.dispatch("DispatchOrder::Widget.Open", &open).unwrap();

        let first = runtime
            .find_aggregate("DispatchOrder", "Widget", "probe")
            .unwrap();
        let second = runtime
            .find_aggregate("DispatchOrder", "Widget", "probe")
            .unwrap();

        assert!(
            Arc::ptr_eq(&first, &second),
            "find_aggregate should return the same cached Arc on a second call, not re-resolve"
        );
    }
}
