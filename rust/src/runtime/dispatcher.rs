use crate::heki::WriteContext;
use crate::identity;
use crate::interp_expr::State;
use crate::interp_givens::evaluate_given;
use crate::interp_mutations::{
    apply_mutation, arithmetic, assign_creation_attributes, coerce_attribute, defaults_for,
    normalize_command_args, parse_literal, refuse_absent_arguments, refuse_unknown_arguments,
    resolve_source,
};
use crate::ir::{Direction, MutationOp};
use crate::runtime::refusal_wording;
use crate::runtime::PersistenceAdapter;
use crate::value_bridge;
use serde_json::{json, Map, Value};
use std::cell::RefCell;
use std::collections::{BTreeMap, HashMap};
use std::fs;
use std::sync::Arc;

pub struct Runtime {
    /// THE DOMAIN, TYPED — and `ir` is DERIVED from it, not held beside it.
    ///
    /// dispatch/dispatch_entity/hydrate and every mutations.rs coercion
    /// helper read this now (M6b), not `ir` — the bug class this arc exists
    /// to close (a typed `Vec<String>` field read back through `.as_str()`,
    /// answering `None` on an array, compiling anyway) has no seam left to
    /// live in along the dispatch core path. `ir` remains for the ~150
    /// scattered reads M6b's second wave hasn't reached yet (mirror/
    /// replication recovery, saga/correlation lookups, `query_read_model`),
    /// and for `bin/parity`'s byte-diffing, which needs the wire shape
    /// regardless of what the live runtime reads.
    domain: crate::ir::Domain,
    ir: Value,
    /// THE TYPED TWIN OF WHAT USED TO BE A JSON ANNOTATION — every closed
    /// set an `admits` can name, resolved once here from `domain`.
    /// `admit_declared_set`'s callers all read this now (M6b); the JSON
    /// annotation step (`resolve_admitted_sets` walking `ir` after the fact
    /// to attach `admitted_members`) is gone from `new` below — this was its
    /// only reader.
    admitted_sets: std::collections::HashMap<String, Vec<String>>,
    /// An aggregate, found once off `self.domain` and cached by (domain,
    /// name) — dispatch reaches for its aggregate on nearly every step, and
    /// `Arc` lets a caller hold it across a later `&mut self` call. Entities,
    /// commands and queries are NOT separately cached — once the owning
    /// Aggregate is in hand, finding one inside its own (small) `Vec` is
    /// cheaper than the HashMap lookup would be.
    typed_aggregate_cache: RefCell<HashMap<String, Arc<crate::ir::Aggregate>>>,
    store: BTreeMap<String, State>,
    adapters: BTreeMap<String, Box<dyn PersistenceAdapter>>,
    mirrors: BTreeMap<String, Vec<(String, Box<dyn PersistenceAdapter>)>>,
    pub events: Vec<Value>,
    pub reactions: Vec<Value>,
    pub sagas: Vec<Value>,
    /// Every `translations/*.bluebook` beside the booted bluebook —
    /// loaded at boot exactly as Ruby's folder glob loads them, so a
    /// malformed edge file refuses a Rust boot as loudly as a Ruby one.
    pub translations: Vec<crate::bluebook::translation::ir::Translation>,
    saga_instances: BTreeMap<String, BTreeMap<String, (String, Map<String, Value>)>>,
    reaction_depth: usize,
    /// SET AROUND ONE DISPATCH CALL, by `deliver_saga_dispatch` — the
    /// correlation key that dispatch is a LEG of, if any. `(correlation
    /// head, value)`. Read by the event-construction sites in `dispatch` and
    /// `dispatch_entity`, which stamp it onto whatever event(s) that one call
    /// announces (see `correlation`'s own doc comment for why: the payload
    /// and own-key tiers both require the command to carry the field, which
    /// most legs never do). NOT part of `self.events` — stamped onto the
    /// `announced` copy used for reactions/sagas only, after the archival
    /// copy is already pushed, so it never reaches `bin/run`'s dump and
    /// never touches what `bin/parity` diffs.
    ///
    /// Saved and restored around each dispatch the same way `reaction_depth`
    /// is, because a leg's own event can recursively trigger further saga
    /// dispatches (a DIFFERENT correlation) before this call returns.
    pending_correlation: Option<(String, String)>,
    // Set by a test to observe dispatch order (Vocabulary::AggregateDispatchOrder /
    // EntityDispatchOrder in language/bluebook.bluebook) ; None in production,
    // always — one Vec push and a match per step is the entire cost of leaving
    // this in. Mirrors CommandInterpreter.trace / EntityInterpreter.trace on
    // the Ruby side.
    pub dispatch_trace: Option<Vec<&'static str>>,
}

const MAX_REACTION_DEPTH: usize = 5;

/// The trigger of the compensating leg. Not an event name — no aggregate
/// announces it — it is the procedure noticing that a leg it dispatched was
/// refused. Declared `on :refused` beside the ordinary legs, because the
/// compensation IS an ordinary leg; only its trigger differs.
const REFUSED: &str = "refused";

// Matches Ruby's `IR::Attribute::PRIMITIVES` — spec/vocabulary_conformance
// holds the two lists equal.
const CORRELATION_KEY_PRIMITIVES: &[&str] = &["String", "Integer", "Float", "TrueClass", "FalseClass"];

/// The Rust twin of `BluebookBuilder#correlation_key_violation` — same
/// algorithm, same reasons, walked over typed structs instead of IR objects.
/// `None` means the path resolves to a real scalar (or resolves to nothing
/// at all, which is not this check's business — see the fallback-tier note
/// where this is called).
fn correlation_key_violation(domain: &crate::ir::Domain, pm: &crate::ir::ProcessManager) -> Option<String> {
    let mut segments = pm.correlates_by.split('.');
    let head = segments.next()?;
    let rest: Vec<&str> = segments.collect();
    let events = reacted_events(pm);

    for (owner, command) in emitting_commands(domain, &events) {
        let Some(attribute) = command.attributes.iter().find(|a| a.name == head) else { continue };

        if let Some(reason) = list_or_scalar_violation(owner, attribute, &rest) {
            return Some(reason);
        }
    }
    None
}

fn reacted_events(pm: &crate::ir::ProcessManager) -> Vec<&str> {
    let mut events: Vec<&str> = vec![pm.starts_on.as_str()];
    events.extend(pm.ends_on.as_deref());
    events.extend(pm.handlers.iter().map(|h| h.event_type.as_str()));

    events
        .into_iter()
        .filter(|event| *event != REFUSED)
        .map(|event| event.rsplit("::").next().unwrap_or(event))
        .collect()
}

fn emitting_commands<'a>(
    domain: &'a crate::ir::Domain,
    events: &[&str],
) -> Vec<(&'a crate::ir::Aggregate, &'a crate::ir::Command)> {
    domain
        .aggregates
        .iter()
        .flat_map(|aggregate| {
            let entity_commands = aggregate.entities.iter().flat_map(|entity| entity.commands.iter());
            aggregate
                .commands
                .iter()
                .chain(entity_commands)
                .map(move |command| (aggregate, command))
        })
        .filter(|(_, command)| command.emits.iter().any(|emitted| events.contains(&emitted.as_str())))
        .collect()
}

fn list_or_scalar_violation(
    owner: &crate::ir::Aggregate,
    attribute: &crate::ir::Attribute,
    segments: &[&str],
) -> Option<String> {
    if attribute.list {
        return Some(format!(
            "{} is a list — a correlation key must name one instance's own field, not a whole collection",
            attribute.name
        ));
    }
    walk_scalar(owner, &attribute.r#type, segments)
}

/// Walks the remaining dotted segments through nested value objects — see
/// `BluebookBuilder#walk_scalar` for the Ruby twin this mirrors field for
/// field.
fn walk_scalar(owner: &crate::ir::Aggregate, type_name: &str, segments: &[&str]) -> Option<String> {
    if segments.is_empty() {
        if CORRELATION_KEY_PRIMITIVES.contains(&type_name) {
            return None;
        }
        return Some(format!(
            "{type_name} is a value object, not a scalar — name one of its own fields, e.g. {}.value",
            type_name.to_lowercase()
        ));
    }

    if CORRELATION_KEY_PRIMITIVES.contains(&type_name) {
        return Some(format!(
            "{type_name} is already a scalar — {} has nothing left to reach",
            segments.join(".")
        ));
    }

    let Some(shape) = owner.value_objects.iter().find(|vo| vo.name == type_name) else {
        return Some(format!("{type_name} is not a value object this domain declares"));
    };

    let (segment, rest) = segments.split_first()?;
    let Some(attribute) = shape.attributes.iter().find(|a| a.name == *segment) else {
        return Some(format!("{type_name} has no field {segment:?}"));
    };
    if attribute.list {
        return Some(format!(
            "{type_name}.{segment} is a list — a correlation key must name one instance's own field, not a whole collection"
        ));
    }

    walk_scalar(owner, &attribute.r#type, rest)
}

fn state_row((id, mut state): (String, State)) -> Value {
    state.insert("id".to_string(), Value::String(id));
    Value::Object(state)
}

fn boot_repository(
    aggregate: &crate::ir::Aggregate,
    bluebook_path: &str,
    persistence: crate::ports::persistence::Persistence,
    domain_name: &str,
) -> Result<Box<dyn PersistenceAdapter>, String> {
    let adapter = persistence.adapter.to_lowercase();
    if adapter == "memory" {
        return Err("Memory cannot be used as a mirror persistence adapter".to_string());
    }

    let mut options = persistence.settings.clone();
    // The domain rides along: a lineage adapter journals per DOMAIN,
    // and the world's own settings never carry that name.
    options.insert("domain".to_string(), domain_name.to_string());
    for field in ["dir", "database"] {
        // Postgres's `database` is a connection identifier (a URL or a
        // database name), never a file — only file-backed adapters
        // resolve these settings relative to the bluebook.
        if adapter == "postgres" || options.get(field).is_some_and(|value| value.contains("://")) {
            continue;
        }
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

// THE DECLARED PATH — `identity::paths` is where that question is answered
// now, and this took the first element of the answer for the whole of it.
// A second reader of one question is what drifts, and this one had: it made
// "reads the first path" and "reads every path" indistinguishable as long as
// every corpus member declared one, which they all did until `Market::Stall`
// first proved composite identity reachable — banking's own `SafeDepositBox`
// (branch_code + box_number) carries it now. The readers that still want a
// single path ask for `identity::paths(..).first()` and say why in the same
// breath.

pub(crate) fn query_text(value: &Value) -> String {
    match value {
        Value::Null => String::new(),
        Value::String(text) => text.clone(),
        Value::Bool(flag) => flag.to_string(),
        // A SINGLE-FIELD VALUE OBJECT, compared by the value inside it — which
        // is what `where(status: "open")` means when `status` is a value object.
        //
        // This used to say it was how aggregate REFERENCES are represented. It
        // is not, any more: a reference is the id itself, and anything else is
        // refused at the payload gate. The unwrap stays for the value objects it
        // was always also doing.
        Value::Object(fields) if fields.len() == 1 => fields
            .values()
            .next()
            .map(query_text)
            .unwrap_or_default(),
        other => other.to_string(),
    }
}

/// An id is a SCALAR, and the PATH is how it is reached — never by opening a
/// value object and taking whatever single field is inside. That unwrapping is
/// gone from the language : a piece that does not name its field is refused when
/// the bluebook loads, so a path is always there to dig.
/// `EntityInterpreter#identity_scalar` is the same reading on the Ruby side — a
/// piece is entry 3, never entry {"value":3}.

/// A query's arguments, rendered the way the adapter will compare them.
///
/// NOT `query_text` alone. Banking asks `Overdrawn` for a `floor` of
/// `{"cents":0,"currency":"USD"}` — two fields, so `query_text` hands back the
/// whole JSON object and the bound clause would match nothing. `query_number`
/// reads the one numeric member, which is the same reading the filter applies a
/// few lines later.
///
/// A NULL argument is omitted rather than rendered: an absent kwarg resolves to
/// an empty target, which the builder skips, which leaves the clause to the
/// filter. That is how `Overdrawn` with no arguments still answers.
fn pushdown_attrs(args: &State) -> HashMap<String, String> {
    args.iter()
        .filter(|(_, value)| !value.is_null())
        .map(|(name, value)| {
            let rendered = match query_number(value) {
                Some(number) if number.fract() == 0.0 && number.abs() < 9.0e15 => {
                    format!("{}", number as i64)
                }
                Some(number) if number.is_finite() => format!("{number}"),
                _ => query_text(value),
            };
            (name.clone(), rendered)
        })
        .collect()
}

fn identity_scalar(value: &Value, field: Option<&str>) -> Value {
    match field {
        Some(name) => value.get(name).cloned().unwrap_or_else(|| value.clone()),
        None => value.clone(),
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

// TAKES THE LIFECYCLE DIRECTLY, not the aggregate/entity that declares it —
// the only field this ever read, and `Aggregate`/`Entity` are distinct typed
// structs (unlike their JSON shape, which let one JSON-Map-taking function
// serve both). One function over `Option<&Lifecycle>` serves both callers
// again, matching the JSON version's genericity without needing a trait.
fn admissible_transition(
    lifecycle: Option<&crate::ir::Lifecycle>,
    command_name: &str,
    state: &State,
) -> Result<Option<(String, String)>, String> {
    let Some(lifecycle) = lifecycle else {
        return Ok(None);
    };
    let field = lifecycle.field.as_str();
    let transitions: Vec<&crate::ir::Transition> =
        lifecycle.transitions.iter().filter(|t| t.command == command_name).collect();
    if transitions.is_empty() {
        return Ok(None);
    }

    let current = state
        .get(field)
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string();
    let admitted = transitions.iter().find(|t| match &t.from_state {
        None => true,
        Some(from) => from.as_str() == current.as_str(),
    });
    if let Some(t) = admitted {
        return Ok(Some((field.to_string(), t.to_state.clone())));
    }

    let mut allowed: Vec<String> = Vec::new();
    for t in &transitions {
        if let Some(from) = &t.from_state {
            let shown = format!("{from:?}");
            if !allowed.contains(&shown) {
                allowed.push(shown);
            }
        }
    }
    let current_shown = format!("{current:?}");
    let allowed_shown = allowed.join(" or ");
    Err(refusal_wording::render(
        "LifecycleRefused",
        "transition_blocked",
        &[
            ("command", command_name),
            ("field", field),
            ("current", &current_shown),
            ("allowed", &allowed_shown),
        ],
    ))
}

/// Loading existing state runs the same default-fill a fresh instance
/// gets: an attribute the record predates — a newly-required field with
/// a declared `default:`, a list added since the record was written —
/// arrives filled instead of absent. Only declared defaults fill in; an
/// attribute with no default stays exactly as stored. Mirrors Ruby's
/// `Instance.hydrate_with_defaults`.
fn fill_hydrate_defaults_typed(
    aggregate: &crate::ir::Aggregate,
    admitted_sets: &HashMap<String, Vec<String>>,
    mut state: State,
) -> State {
    let Ok(defaults) = defaults_for(aggregate, admitted_sets) else {
        return state;
    };
    for (name, value) in defaults {
        if value.is_null() || state.contains_key(&name) {
            continue;
        }
        state.insert(name, value);
    }
    state
}

impl Runtime {
    pub fn new(domain: crate::ir::Domain) -> Self {
        let ir = crate::projector::ir_json::domain_to_value(&domain);
        let admitted_sets = crate::runtime::mutations::admitted_sets_of_domain(&domain);
        Runtime {
            ir,
            admitted_sets,
            domain,
            store: BTreeMap::new(),
            adapters: BTreeMap::new(),
            mirrors: BTreeMap::new(),
            events: Vec::new(),
            reactions: Vec::new(),
            sagas: Vec::new(),
            translations: Vec::new(),
            saga_instances: BTreeMap::new(),
            reaction_depth: 0,
            pending_correlation: None,
            dispatch_trace: None,
            typed_aggregate_cache: RefCell::new(HashMap::new()),
        }
    }

    fn trace_step(&mut self, name: &'static str) {
        if let Some(trace) = &mut self.dispatch_trace {
            trace.push(name);
        }
    }

    /// Stamps `pending_correlation` onto the `announced` copy of an event
    /// AFTER the archival copy has already been pushed to `self.events` —
    /// see `pending_correlation`'s own doc comment for why the two copies
    /// must diverge.
    fn stamp_pending_correlation(&self, event: &mut Value) {
        let Some((field, value)) = &self.pending_correlation else {
            return;
        };
        let object = event.as_object_mut().expect("event is an object");
        object
            .entry("correlation")
            .or_insert_with(|| Value::Object(Map::new()))
            .as_object_mut()
            .expect("correlation is an object")
            .insert(field.clone(), Value::String(value.clone()));
    }

    /// Load one native Bluebook and attach the persistence declared by its
    /// neighbouring world and hecksagon files. Hosts register impure adapter
    /// factories (for example Sqlite) before booting; Memory and Heki are
    /// available in the core runtime itself.
    /// BOOT A COMPILED-IN DOMAIN, WITH NO FILE ANYWHERE.
    ///
    /// `boot` takes a PATH, and every projected domain still needed its
    /// `.bluebook` to exist — read for its chapter name, and its directory
    /// walked for the neighbouring world. So "compiled in" carried an asterisk:
    /// the parse was gone, the file was not.
    ///
    /// This is the same runtime with the asterisk removed. The domain comes
    /// from the binary; nothing is read, nothing is walked, and no path is
    /// named. What a caller gives up is the deployment: adapters are attached
    /// by the host afterwards, because a world is a fact about WHERE this runs
    /// and this function deliberately knows nothing about that. In-memory until
    /// somebody says otherwise.
    ///
    /// `boot` stays the path for a domain on disk, which is the developing
    /// case: edit a bluebook, run it, no regeneration step. Two doors, and the
    /// projection is what makes the second one possible.
    pub fn boot_projected(chapter: &str) -> Result<Self, String> {
        let domain = crate::bluebook::projected::by_name(chapter).ok_or_else(|| {
            format!(
                "this binary carries no projection of {chapter:?} — it holds {}. \
                 Project one with `bin/ir_rust <bluebook>`, or boot from the file.",
                crate::bluebook::projected::names().join(", ")
            )
        })?;
        Ok(Self::new(domain))
    }

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
        // A PROJECTED DOMAIN IS PREFERRED, AND NOT PARSED.
        //
        // `bin/ir_rust` compiles a chapter in as Rust values, checked against
        // Ruby's own frozen IR at build time. When one exists, the source is
        // never read for meaning — so `strict_boot` does not apply to it. That
        // scan exists because Rust's PARSER silently drops constructs it cannot
        // read; a projection drops nothing, which is the point of having one.
        //
        // A chapter with no projection parses exactly as before. `--dump` parses
        // either way, so `bin/parity`'s first stage still holds the two PARSERS
        // to each other while the run stages exercise this path.
        let projected = crate::bluebook::projected::by_source(&source);

        let domain = match projected {
            Some(domain) => domain,
            None => {
                let parsed = crate::bluebook::parser::parse(&source);
                // Interim host-language strictness — see runtime::strict_boot.
                if let Some(miss) = crate::runtime::strict_boot::scan(&source) {
                    return Err(format!(
                        "cannot boot {}::{}: this runtime could not read '{}' (did you mean '{}'?) — \
                         a construct it cannot read refuses rather than half-reads; \
                         host-language strictness is partial until the specializer",
                        parsed.name, miss.aggregate, miss.keyword, miss.suggestion
                    ));
                }
                parsed
            }
        };
        // THE FIELD, NAMED — never the value object that carries it, the same
        // rule `ProcessManagerBuilder#validate!` holds Ruby to. A bare
        // `correlates_by :end_to_end` reads whatever the payload holds under
        // that key AS the correlation key, and Ruby and Rust disagree about
        // what a non-scalar key even is. Checked here rather than inside
        // `parser::parse` for the same reason `strict_boot` lives here: a
        // fresh parse is host-language strictness, not the second parser
        // `--dump` exists to be.
        if let Some(process_manager) = domain
            .process_managers
            .iter()
            .find(|process_manager| !process_manager.correlates_by.contains('.'))
        {
            return Err(format!(
                "cannot boot {}::{}: correlates_by {:?} names a whole field rather than one of its \
                 scalars — say which one, e.g. \"{}.value\"",
                domain.name,
                process_manager.name,
                process_manager.correlates_by,
                process_manager.correlates_by
            ));
        }
        // `correlates_by` NAMES A SCALAR, NOW CHECKED RATHER THAN TRUSTED —
        // the Rust twin of `BluebookBuilder#validate_correlation_keys!`. The
        // dot check above is syntactic; this walks the path for real, against
        // whichever command actually emits an event this process manager
        // reacts to, and refuses if it still lands on a value object
        // (RESTART.md's named gap: Ruby keys a saga on the object itself,
        // Rust on its JSON text). A path whose first segment no emitting
        // command declares is skipped, not refused — correlation has two
        // fallback tiers below the payload dig (a stamp, then the emitting
        // aggregate's own reference key), so an absent field is not this
        // check's business, only a resolvable-but-non-scalar one is.
        for process_manager in &domain.process_managers {
            if let Some(reason) = correlation_key_violation(&domain, process_manager) {
                return Err(format!(
                    "cannot boot {}::{}: correlates_by {:?}, but {reason}",
                    domain.name, process_manager.name, process_manager.correlates_by
                ));
            }
        }
        // The name is kept before the domain moves into the runtime — boot
        // still needs it to bind repositories, and the runtime owns it now.
        let domain_name = domain.name.clone();
        let aggregates = domain.aggregates.clone();
        let mut runtime = Self::new(domain);
        let source_text = bluebook_path.to_string_lossy();

        if let Some(directory) = bluebook_path.parent() {
            for (_, translation_source) in
                crate::bluebook::project_loader::translation_sources(directory)?
            {
                runtime
                    .translations
                    .push(crate::bluebook::translation::parser::parse(&translation_source)?);
            }
        }

        let mut adapter_names = BTreeMap::new();
        let mut capable = BTreeMap::new();
        for aggregate in &aggregates {
            let bindings = crate::ports::persistence::resolve_all_for(&source_text, &aggregate.name)?;
            adapter_names.insert(aggregate.name.clone(), bindings.authoritative.adapter.clone());
            if bindings.authoritative.adapter.to_lowercase() != "memory" {
                let repository = boot_repository(aggregate, &source_text, bindings.authoritative, &domain_name)?;
                runtime.attach(&aggregate.name, repository);
            }
            for mirror in bindings.mirrors {
                let name = mirror.adapter.clone();
                runtime.attach_mirror(&aggregate.name, name, boot_repository(aggregate, &source_text, mirror, &domain_name)?);
            }
            capable.insert(
                aggregate.name.clone(),
                runtime.adapters.get(&aggregate.name).map(|adapter| adapter.lineage_capable()).unwrap_or(false),
            );
            runtime.recover_mirrors(&aggregate.name)?;
        }

        // Eras belong to the adapters that HAVE them. A lineage-capable
        // adapter (Postgres) holds its era facts as rows beside its
        // data and gets the whole domain delegated to its own gate —
        // which recognizes stored eras structurally and refuses toward
        // the Ruby scaffold on anything unminted, since era identity is
        // minted on the Ruby side alone. Every other adapter has no era
        // to hold, and holding one for it would record history about
        // data nothing can act on.
        //
        // The compute gate is not an era fact and runs regardless.
        let context = crate::runtime::era_check::EraContext {
            domain: &runtime.domain,
            translations: &runtime.translations,
            adapters: &adapter_names,
            capable: &capable,
        };
        crate::runtime::era_check::check_compute_rules(&context)?;
        if capable.values().any(|declared| *declared) {
            let current_shape = crate::runtime::storage_shape::project(&runtime.domain);
            let translations = runtime.translations.clone();
            let capable_aggregate = aggregates
                .iter()
                .find(|aggregate| capable.get(&aggregate.name).copied().unwrap_or(false))
                .map(|aggregate| aggregate.name.clone());
            if let Some(name) = capable_aggregate {
                let resolved = match runtime.adapters.get_mut(&name) {
                    Some(adapter) => adapter.era_gate(&domain_name, &source, &current_shape, &translations)?,
                    None => None,
                };
                if let Some(era) = resolved {
                    for aggregate in &aggregates {
                        if capable.get(&aggregate.name).copied().unwrap_or(false) {
                            if let Some(adapter) = runtime.adapters.get_mut(&aggregate.name) {
                                adapter.adopt_era(era);
                            }
                        }
                    }
                }
            }
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
        for aggregate in &self.domain.aggregates {
            let Some(adapter) = self.adapters.get(aggregate.name.as_str()) else {
                continue;
            };
            for state in adapter.all() {
                found.insert(
                    format!("{}::{}#{}", self.domain.name, aggregate.name, state.id),
                    fill_hydrate_defaults_typed(aggregate, &self.admitted_sets, value_bridge::from_state(state)),
                );
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
        let aggregate = self.find_aggregate_typed(domain, aggregate_name, dotted)?;
        let entity = Runtime::find_entity_typed(&aggregate, entity_name)?;
        let command = Runtime::find_entity_command_typed(&entity, command_name)?;
        self.refuse_object_references(domain, &command, args)?;
        let normalized_args = normalize_command_args(&aggregate, &command, args, &self.admitted_sets)?;
        self.trace_step("normalize_args");
        // An entity command can declare a reference-typed attribute the same
        // way an aggregate command can (CommandRules#resolve_references is
        // shared by both interpreters on the Ruby side too), even though
        // nothing in the real corpus does yet. Part of Vocabulary::EntityDispatchOrder.
        self.resolve_references(domain, &command, &normalized_args)?;
        self.trace_step("resolve_references");
        let args = &normalized_args;

        // The parent's identity is derived exactly as an aggregate command
        // derives its own — every declared path, dug and joined — so a piece
        // hanging off a composite head is reached by naming both its parts.
        // `id` stays as the fallback for a caller quoting an id back whole.
        let identity = identity::reading_of_paths(&aggregate.identified_by);
        let parent_id = identity::of_paths(&aggregate.identified_by, args)
            .or_else(|| args.get("id").map(query_text).filter(|id| !id.is_empty()))
            .ok_or_else(|| {
                refusal_wording::render(
                    "NotFound",
                    "entity_parent_no_identity",
                    &[
                        ("command", command_name),
                        ("aggregate", aggregate_name),
                        ("entity", entity_name),
                        ("identity", &identity),
                    ],
                )
            })?;

        let mut state = if let Some(adapter) = self.adapters.get(aggregate_name) {
            adapter.find(&parent_id).map(value_bridge::from_state).ok_or_else(|| {
                let offered = format!("{parent_id:?}");
                refusal_wording::render(
                    "NotFound",
                    "record_missing",
                    &[("aggregate", aggregate_name), ("identity", &identity), ("offered", &offered)],
                )
            })?
        } else {
            let key = format!("{}::{}#{}", domain, aggregate_name, parent_id);
            self.store.get(&key).cloned().ok_or_else(|| {
                let offered = format!("{parent_id:?}");
                refusal_wording::render(
                    "NotFound",
                    "record_missing",
                    &[("aggregate", aggregate_name), ("identity", &identity), ("offered", &offered)],
                )
            })?
        };
        self.trace_step("hydrate_parent");

        let list_attr = aggregate
            .attributes
            .iter()
            .find(|a| a.list && a.r#type == entity_name)
            .map(|a| a.name.clone())
            .ok_or_else(|| {
                refusal_wording::render(
                    "UnknownVerb",
                    "entity_holds_no_list",
                    &[("aggregate", aggregate_name), ("entity", entity_name)],
                )
            })?;

        // ONE ELEMENT, MATCHED ON EVERY PART OF ITS IDENTITY — not just the
        // first. A piece's identity may be several paths, the same shape a
        // head's can be, so a dispatch that names the element has to supply
        // every part and every part has to agree with the stored one.
        // `EntityInterpreter#element_of` is the same reading on the Ruby side.
        //
        // A PIECE's identity is a path like a head's : the caller passes the
        // head attribute and the id is the scalar dug out of it.
        let entity_reading = identity::reading_of_paths(&entity.identified_by);
        let mut wants: Vec<(String, Option<String>, Value)> = Vec::new();
        for path in &entity.identified_by {
            let (head, field) = identity::split(path);
            let raw = args.get(head).cloned().ok_or_else(|| {
                refusal_wording::render(
                    "NotFound",
                    "entity_element_no_identity",
                    &[("command", command_name), ("entity", entity_name), ("identity", &entity_reading)],
                )
            })?;
            // An entity's identity is a declared attribute like any other, so
            // it is coerced through its own type BEFORE it is matched —
            // EntityInterpreter#element_of has always done this. Matching the
            // raw argument instead meant a LedgerSequence of 0 was reported as
            // a missing element rather than as the invariant it actually
            // violates, so the two runtimes refused the same dispatch for
            // different reasons. It also makes a scalar stand in for a
            // single-field value object here, the way it does everywhere else.
            // Part of Vocabulary::EntityDispatchOrder's locate_element.
            let want = match entity.attributes.iter().find(|held| held.name == head) {
                Some(attribute) => coerce_attribute(&aggregate, attribute, &raw, &self.admitted_sets)?,
                None => raw,
            };
            wants.push((head.to_string(), field.map(str::to_string), want));
        }

        let mut elements = state
            .get(&list_attr)
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
        let position = elements
            .iter()
            .position(|el| {
                wants
                    .iter()
                    .all(|(head, _, want)| el.get(head) == Some(want))
            })
            .ok_or_else(|| {
                // AS TEXT, not as JSON. `identity_scalar` hands back a Value and
                // Display on one QUOTES a string — Ruby interpolates the dug
                // scalar, so `wednesday` read `"wednesday"` here. Invisible
                // until a piece was identified by something other than a
                // number: banking's LedgerEntry is a sequence, and a number
                // renders the same either way.
                let named = wants
                    .iter()
                    .map(|(_, field, want)| query_text(&identity_scalar(want, field.as_deref())))
                    .collect::<Vec<_>>()
                    .join(", ");
                let parent_id_shown = format!("{parent_id:?}");
                refusal_wording::render(
                    "NotFound",
                    "entity_element_missing",
                    &[
                        ("entity", entity_name),
                        ("identity", &entity_reading),
                        ("wants", &named),
                        ("aggregate", aggregate_name),
                        ("parent_id", &parent_id_shown),
                    ],
                )
            })?;
        let mut element = elements[position].as_object().cloned().unwrap_or_default();
        self.trace_step("locate_element");

        for given in &command.givens {
            let canonical = crate::projector::ir_json::canonicalise(&given.canonical);
            if !evaluate_given(&canonical, &element, args)? {
                let description = given.description.as_deref().unwrap_or("");
                return Err(format!("{} refused — {}", command_name, description));
            }
        }
        self.trace_step("enforce_givens");
        let transition_to = admissible_transition(entity.lifecycle.as_ref(), command_name, &element)?;
        self.trace_step("admissible_transition");

        let old_element = if command.ensures.is_empty() {
            None
        } else {
            Some(element.clone())
        };
        for mutation in &command.mutations {
            match mutation.op {
                MutationOp::Increment | MutationOp::Decrement => {
                    let operation = if matches!(mutation.op, MutationOp::Increment) { "increment" } else { "decrement" };
                    let updated = arithmetic(&element, &mutation.target, operation, mutation, args)?;
                    element.insert(mutation.target.clone(), updated);
                }
                _ => {
                    let value = resolve_source(mutation, args);
                    let coerced = entity
                        .attributes
                        .iter()
                        .find(|attribute| attribute.name == mutation.target)
                        .map(|attribute| coerce_attribute(&aggregate, attribute, &value, &self.admitted_sets))
                        .transpose()?
                        .unwrap_or(value);
                    element.insert(mutation.target.clone(), coerced);
                }
            }
        }
        self.trace_step("apply_mutations");
        if let Some((field, to_state)) = transition_to {
            element.insert(field, Value::String(to_state));
            self.trace_step("advance_lifecycle");
        }
        for rule in &command.ensures {
            let canonical = crate::projector::ir_json::canonicalise(&rule.canonical);
            let mut attrs = args.clone();
            attrs.insert(
                "old".to_string(),
                Value::Object(old_element.clone().unwrap_or_default()),
            );
            if !evaluate_given(&canonical, &element, &attrs)? {
                let description = rule.description.as_deref().unwrap_or("");
                return Err(format!("{} refused — {}", command_name, description));
            }
        }
        self.trace_step("enforce_ensures");

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
        for name in &command.emits {
            let mut event = json!({
                "name": name,
                "aggregate": format!("{}::{}", domain, aggregate_name),
                "id": parent_id,
                "payload": Value::Object(args.clone()),
            });
            self.events.push(event.clone());
            self.stamp_pending_correlation(&mut event);
            announced.push(event);
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
        let aggregate = self.find_aggregate_typed(&domain, &aggregate_name, verb)?;
        if query_name.contains('.') {
            return self.query_entity(&domain, &aggregate_name, &aggregate, &query_name, args);
        }
        let declared = Runtime::find_query_typed(&aggregate, &query_name)?;

        // A query's arguments are coerced against their declared types exactly as
        // a command's are — mirrors Ruby's QueryInterpreter#normalize_args. Without
        // this a query took whatever it was handed : Ruby refused
        // `cents: "lots"` for a Money and Rust answered with an empty result set,
        // agreeing about nothing. Reads enter through the aggregate, so they meet
        // the same gate writes do.
        let mut args = args.clone();
        for attribute in &declared.attributes {
            let Some(given) = args.get(&attribute.name).cloned() else {
                continue;
            };
            let coerced = coerce_attribute(&aggregate, attribute, &given, &self.admitted_sets)?;
            args.insert(attribute.name.clone(), coerced);
        }
        let args = &args;

        let mut matched: Vec<(String, State)> = Vec::new();
        // CANDIDATES, then the SAME predicate as ever. An adapter that can narrow
        // says so ; the filter below still decides, so the answer is unchanged by
        // whatever the adapter could or could not push. Only the aggregate path
        // pushes — see `candidate_records`.
        for (key, state) in self.candidate_records_typed(&domain, &aggregate_name, &aggregate, &declared.wheres, args) {
            let holds = declared.wheres.iter().all(|clause| {
                let held = state.get(&clause.field).cloned().unwrap_or(Value::Null);
                let clause_value = Value::String(clause.value.clone());
                let want = resolve_query_value(Some(&clause_value), args);
                match clause.op {
                    crate::ir::WhereOp::Ne => query_value(&held) != query_value(&want),
                    crate::ir::WhereOp::Lt => query_less_than(&held, &want),
                    crate::ir::WhereOp::Lte => query_at_most(&held, &want),
                    crate::ir::WhereOp::Gt => query_greater_than(&held, &want),
                    crate::ir::WhereOp::Gte => query_at_least(&held, &want),
                    crate::ir::WhereOp::In => query_members(&want).contains(&query_text(&held)),
                    crate::ir::WhereOp::Contains => query_members(&held).contains(&query_text(&want)),
                    crate::ir::WhereOp::Eq => query_value(&held) == query_value(&want),
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

        if let Some(order) = &declared.order_by {
            matched.sort_by(|(a_id, a), (b_id, b)| {
                let left = a.get(&order.field).cloned().unwrap_or(Value::Null);
                let right = b.get(&order.field).cloned().unwrap_or(Value::Null);
                query_order(&left, &right).then_with(|| a_id.cmp(b_id))
            });
            if matches!(order.direction, Direction::Desc) {
                matched.reverse();
            }
        }

        let capped: Vec<(String, State)> = match &declared.limit {
            Some(limit) => {
                let limit_value = Value::String(limit.value.clone());
                let n = query_limit(&resolve_query_value(Some(&limit_value), args));
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
        if domain != self.domain.name {
            let domain_shown = format!("{domain:?}");
            return Err(refusal_wording::render(
                "UnknownVerb",
                "no_domain",
                &[("domain", &domain_shown), ("verb", query_name)],
            ));
        }
        // Cloned, not borrowed: the loop below needs `&mut self` (through
        // `all_records_typed`) while still reading `model` — same reason
        // `find_aggregate_typed` hands back an `Arc` rather than a borrow.
        let model = self
            .domain
            .read_models
            .iter()
            .find(|model| crate::naming::snake(&model.name) == query_name)
            .cloned()
            .ok_or_else(|| {
                let query_shown = format!("{query_name:?}");
                refusal_wording::render(
                    "UnknownVerb",
                    "no_read_model",
                    &[("domain", domain), ("query", &query_shown)],
                )
            })?;
        let reference_name = model.reference_name.as_str();
        // AN ASK'S REFERENCE IS AN ID TOO. Without this, `query_text` below would
        // quietly open a wrapped one and answer, while Ruby read it whole and
        // found nothing — a split that shows only when a stale caller exists.
        // ReadModelInterpreter#refuse_object_reference is the same sentence.
        if args.get(reference_name).map(Value::is_object).unwrap_or(false) {
            return Err(refusal_wording::render(
                "TypeMismatch",
                "read_model_object_reference",
                &[("query", query_name), ("field", reference_name)],
            ));
        }
        let reference_id = args.get(reference_name).map(query_text).unwrap_or_default();
        let mut projected: Vec<(String, Vec<(String, State)>)> = Vec::new();
        let mut report = Map::new();
        for head in &model.aggregate_heads {
            let aggregate_name = head.aggregate.as_str();
            let name = head.r#as.clone();
            // find_aggregate_typed is cache-backed, and this is the same
            // aggregate whether the row is the reference target or a
            // projected source — resolved once here and reused for both
            // branches below (the original called the equivalent lookup
            // twice in the else branch).
            let aggregate = self.find_aggregate_typed(domain, aggregate_name, query_name)?;
            let mut rows = self.all_records_typed(domain, aggregate_name, &aggregate);
            if aggregate_name == model.reference_target {
                rows.retain(|(id, _)| id == &reference_id);
                if rows.is_empty() {
                    let offered = format!("{reference_id:?}");
                    return Err(refusal_wording::render(
                        "NotFound",
                        "read_model_reference_missing",
                        &[("aggregate", aggregate_name), ("offered", &offered)],
                    ));
                }
            } else {
                rows.retain(|(_, state)| projected.iter().any(|(source_name, source_rows)| {
                    let reference_type = format!("Reference<{source_name}>");
                    let fields: Vec<&str> = aggregate.attributes.iter()
                        .filter(|attribute| attribute.r#type == reference_type)
                        .map(|attribute| attribute.name.as_str())
                        .collect();
                    fields.iter().any(|field| source_rows.iter().any(|(id, _)| state.get(*field).map(query_text).as_deref() == Some(id.as_str())))
                }));
            }
            rows.sort_by(|(left, _), (right, _)| left.cmp(right));
            report.insert(name.clone(), if head.many { Value::Array(rows.iter().cloned().map(state_row).collect()) } else { rows.first().cloned().map(state_row).unwrap_or(Value::Null) });
            projected.push((aggregate_name.to_string(), rows));
        }
        Ok(vec![Value::Object(report)])
    }

    fn query_entity(
        &mut self,
        domain: &str,
        aggregate_name: &str,
        aggregate: &crate::ir::Aggregate,
        dotted: &str,
        args: &State,
    ) -> Result<Vec<Value>, String> {
        let (entity_name, query_name) = crate::naming::split_dotted(dotted);
        let entity = Runtime::find_entity_typed(aggregate, entity_name)?;
        let declared = Runtime::find_entity_query_typed(&entity, query_name)?;
        let list_attr = aggregate
            .attributes
            .iter()
            .find(|a| a.list && a.r#type == entity_name)
            .map(|a| a.name.clone())
            .ok_or_else(|| {
                refusal_wording::render(
                    "UnknownVerb",
                    "entity_holds_no_list",
                    &[("aggregate", aggregate_name), ("entity", entity_name)],
                )
            })?;

        let parent_key = crate::naming::reference_key(aggregate_name);
        let mut rows: Vec<Value> = Vec::new();
        for (parent_id, state) in self.all_records_typed(domain, aggregate_name, aggregate) {
            for element in state
                .get(&list_attr)
                .and_then(Value::as_array)
                .cloned()
                .unwrap_or_default()
            {
                let Some(element) = element.as_object() else {
                    continue;
                };
                let holds = declared.wheres.iter().all(|clause| {
                    let held = element.get(&clause.field).cloned().unwrap_or(Value::Null);
                    let clause_value = Value::String(clause.value.clone());
                    let want = resolve_query_value(Some(&clause_value), args);
                    match clause.op {
                        crate::ir::WhereOp::Ne => query_value(&held) != query_value(&want),
                        crate::ir::WhereOp::Lt => query_less_than(&held, &want),
                        crate::ir::WhereOp::Lte => query_at_most(&held, &want),
                        crate::ir::WhereOp::Gt => query_greater_than(&held, &want),
                        crate::ir::WhereOp::Gte => query_at_least(&held, &want),
                        crate::ir::WhereOp::In => query_members(&want).contains(&query_text(&held)),
                        crate::ir::WhereOp::Contains => query_members(&held).contains(&query_text(&want)),
                        crate::ir::WhereOp::Eq => query_value(&held) == query_value(&want),
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
        // The HEADS, not the paths : a row is a stored element, and what it
        // keys is the attribute the identity is dug out of. EVERY head, in
        // declaration order, for the same reason the parent leads — a part
        // that ties breaks no tie, and a piece known by two facts has a second
        // one to try. `QueryInterpreter#ordered_elements` is the twin.
        let entity_keys: Vec<String> = identity::heads_of_paths(&entity.identified_by)
            .into_iter()
            .map(str::to_string)
            .collect();
        rows.sort_by(|a, b| {
            let left_parent = query_text(a.get(&parent_key).unwrap_or(&Value::Null));
            let right_parent = query_text(b.get(&parent_key).unwrap_or(&Value::Null));
            let mut ordering = left_parent.cmp(&right_parent);
            for key in &entity_keys {
                if ordering != std::cmp::Ordering::Equal {
                    break;
                }
                let left = a.get(key).cloned().unwrap_or(Value::Null);
                let right = b.get(key).cloned().unwrap_or(Value::Null);
                ordering = query_order(&left, &right);
            }
            ordering
        });

        if let Some(order) = &declared.order_by {
            rows.sort_by(|a, b| {
                let left = a.get(&order.field).cloned().unwrap_or(Value::Null);
                let right = b.get(&order.field).cloned().unwrap_or(Value::Null);
                query_order(&left, &right)
            });
            if matches!(order.direction, Direction::Desc) {
                rows.reverse();
            }
        }
        if let Some(limit) = &declared.limit {
            let limit_value = Value::String(limit.value.clone());
            rows.truncate(query_limit(&resolve_query_value(Some(&limit_value), args)));
        }
        Ok(rows)
    }

    /// ROWS THAT MIGHT MATCH, from an adapter that can narrow.
    ///
    /// The caller filters these with the full predicate regardless, so this is
    /// free to return too many and must never return too few — the contract on
    /// `PersistenceAdapter::query`.
    ///
    /// ONLY THE AGGREGATE QUERY PATH USES THIS. An entity query's clauses apply
    /// to elements INSIDE a JSON list column, which this schema cannot express,
    /// and the builder filters by column NAME alone — so a piece's field sharing
    /// a parent column's name would narrow the parent set by a clause meant for
    /// the child. A read model has no clauses at all.
    fn candidate_records_typed(
        &mut self,
        domain: &str,
        aggregate_name: &str,
        aggregate: &crate::ir::Aggregate,
        wheres: &[crate::ir::WhereClause],
        args: &State,
    ) -> Vec<(String, State)> {
        let narrowed = (!wheres.is_empty())
            .then(|| self.adapters.get(aggregate_name))
            .flatten()
            .and_then(|adapter| adapter.query(wheres, &pushdown_attrs(args)));

        match narrowed {
            Some(states) => states
                .into_iter()
                .map(|state| (state.id.clone(), value_bridge::from_state(&state)))
                .collect(),
            None => self.all_records_typed(domain, aggregate_name, aggregate),
        }
    }

    fn all_records_typed(
        &mut self,
        domain: &str,
        aggregate_name: &str,
        aggregate: &crate::ir::Aggregate,
    ) -> Vec<(String, State)> {
        if let Some(adapter) = self.adapters.get(aggregate_name) {
            return adapter
                .all()
                .into_iter()
                .map(|s| (s.id.clone(), fill_hydrate_defaults_typed(aggregate, &self.admitted_sets, value_bridge::from_state(s))))
                .collect();
        }
        let prefix = format!("{}::{}#", domain, aggregate_name);
        self.store
            .iter()
            .filter(|(key, _)| key.starts_with(&prefix))
            .map(|(key, state)| (key[prefix.len()..].to_string(), fill_hydrate_defaults_typed(aggregate, &self.admitted_sets, state.clone())))
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
        command: &crate::ir::Command,
        args: &State,
    ) -> Result<(), String> {
        for attribute in &command.attributes {
            let Some(target_name) = attribute
                .r#type
                .strip_prefix("Reference<")
                .and_then(|rest| rest.strip_suffix('>'))
            else {
                continue;
            };
            let Some(held) = args.get(&attribute.name) else { continue };
            if held.is_null() {
                continue;
            }
            let Ok(target) = self.find_aggregate_typed(domain, target_name, &attribute.name) else {
                continue;
            };
            // The id itself. This opened a one-field object first, which is the
            // reference unwrap in its second copy — a reference that arrives as
            // anything but its id is refused at the payload gate now, so there is
            // nothing here to open.
            let key = query_text(held);
            if key.is_empty() {
                continue;
            }
            // The HEADS name what a caller passes, so they are what a refusal
            // names — every one of them, because a composite is addressed by
            // all its parts and naming only the first tells the caller to pass
            // something that would not be enough.
            let identity = identity::heads_of_paths(&target.identified_by).join(", ");
            let found = self
                .all_records_typed(domain, target_name, &target)
                .into_iter()
                .any(|(id, _)| id == key);
            if !found {
                let key_shown = format!("{key:?}");
                return Err(refusal_wording::render(
                    "NotFound",
                    "reference_target_missing",
                    &[("target", target_name), ("heads", &identity), ("key", &key_shown)],
                ));
            }
        }
        Ok(())
    }

    pub fn dispatch(&mut self, verb: &str, args: &State) -> Result<State, String> {
        let (domain, aggregate_name, command_name) = parse_verb(verb)?;
        if command_name.contains('.') {
            return self.dispatch_entity(&domain, &aggregate_name, &command_name, args);
        }
        let aggregate = self.find_aggregate_typed(&domain, &aggregate_name, verb)?;
        let command = Runtime::find_command_typed(&aggregate, &command_name).ok_or_else(|| {
            let shown = format!("{command_name:?}");
            refusal_wording::render(
                "UnknownVerb",
                "aggregate_no_command",
                &[("aggregate", &aggregate_name), ("command", &shown)],
            )
        })?;
        refuse_unknown_arguments(&aggregate, &command, args, &self.correlation_keys(&domain))?;
        self.trace_step("refuse_unknown_arguments");
        // Unknown first, deliberately : a payload that both misspells one name and
        // omits another is more usefully told about the name that does not exist.
        refuse_absent_arguments(&command, args)?;
        self.trace_step("refuse_absent_arguments");
        self.refuse_object_references(&domain, &command, args)?;
        let normalized_args = normalize_command_args(&aggregate, &command, args, &self.admitted_sets)?;
        self.trace_step("normalize_args");
        self.resolve_references(&domain, &command, &normalized_args)?;
        self.trace_step("resolve_references");
        let args = &normalized_args;

        let creates = command.references.is_none();

        let (id, mut state) = self.hydrate(&aggregate, &command, args, creates)?;
        self.trace_step("hydrate");

        for given in &command.givens {
            let canonical = crate::projector::ir_json::canonicalise(&given.canonical);
            if !evaluate_given(&canonical, &state, args)? {
                let description = given.description.as_deref().unwrap_or("");
                return Err(format!("{} refused — {}", command_name, description));
            }
        }
        self.trace_step("enforce_givens");

        let transition_to = admissible_transition(aggregate.lifecycle.as_ref(), &command_name, &state)?;
        self.trace_step("admissible_transition");

        if creates {
            assign_creation_attributes(&mut state, &aggregate, &command, args, &self.admitted_sets)?;
            self.trace_step("assign_creation_attributes");
        }
        // The state as the givens saw it — what `old` names inside an
        // ensures. Cloned only when the command declares one.
        let old_state = if command.ensures.is_empty() {
            None
        } else {
            Some(state.clone())
        };
        for mutation in &command.mutations {
            apply_mutation(&mut state, &aggregate, mutation, args, &self.admitted_sets)?;
        }
        self.trace_step("apply_mutations");
        if let Some((field, to_state)) = transition_to {
            state.insert(field, Value::String(to_state));
            self.trace_step("advance_lifecycle");
        }
        for rule in &command.ensures {
            let canonical = crate::projector::ir_json::canonicalise(&rule.canonical);
            let mut attrs = args.clone();
            attrs.insert(
                "old".to_string(),
                Value::Object(old_state.clone().unwrap_or_default()),
            );
            if !evaluate_given(&canonical, &state, &attrs)? {
                let description = rule.description.as_deref().unwrap_or("");
                return Err(format!("{} refused — {}", command_name, description));
            }
        }
        self.trace_step("enforce_ensures");

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
        for name in &command.emits {
            let mut event = json!({
                "name": name,
                "aggregate": format!("{}::{}", domain, aggregate_name),
                "id": id,
                "payload": Value::Object(args.clone()),
            });

            self.events.push(event.clone());
            self.stamp_pending_correlation(&mut event);
            announced.push(event);
        }
        self.trace_step("emit");

        for event in &announced {
            self.react_to(event, &domain);
        }

        for event in &announced {
            self.advance_sagas(event, &domain);
        }

        // THE DERIVED ID, HANDED BACK UNDER THE PATH IT CAME FROM — and only
        // when there is ONE path to hand it back under. A composite's id is the
        // JOIN of its parts, so filing the whole join under any single part
        // would name that part something it is not. Ruby says the same by
        // saying nothing: `Instance#materialize_identity!` reads `identified_by`,
        // which is the single head and is nil the moment an identity has two,
        // so it returns early and leaves the state alone.
        let mut result = state;
        if let [only] = aggregate.identified_by.as_slice() {
            result.insert(only.clone(), Value::String(id));
        }
        Ok(result)
    }

    // THE SAME QUESTION THE "ACTS ON AN EXISTING" BRANCH BELOW ANSWERS BY
    // FINDING A RECORD, ASKED WITHOUT NEEDING ONE BACK — an adapter-backed
    // aggregate is checked through the adapter, an in-memory one through the
    // compiled store, matching the two lookup paths `hydrate`'s non-creating
    // branch already reads.
    fn record_exists(&self, aggregate_name: &str, id: &str) -> bool {
        if let Some(adapter) = self.adapters.get(aggregate_name) {
            return adapter.find(id).is_some();
        }
        self.store
            .keys()
            .any(|key| key.ends_with(&format!("::{aggregate_name}#{id}")))
    }

    fn hydrate(
        &mut self,
        aggregate: &crate::ir::Aggregate,
        command: &crate::ir::Command,
        args: &State,
        creates: bool,
    ) -> Result<(String, State), String> {
        let aggregate_name = aggregate.name.as_str();
        let command_name = command.name.as_str();

        // THE DECLARED PATHS, not just their heads — the same reading Ruby's
        // `identity_reading` quotes back, so a refusal names exactly what the
        // bluebook said ("row.value, number.value", not "row").
        let reading = identity::reading_of_paths(&aggregate.identified_by);

        if creates {
            // NOTHING IS MINTED. An invented identity is neither derived from
            // the record nor permanently associated with it — Rust counted,
            // Ruby drew a random hex, and the same dispatch made two different
            // records. A creating command that cannot say WHICH ONE THIS IS is
            // refused, and an aggregate with no `identified_by` has to be told.
            //
            // `identity::of_paths` is the whole derivation now: it follows
            // every declared path, refuses a part that is absent OR blank —
            // `{value: ""}` is a non-empty wrapper around nothing, and "" is
            // not a fact about anything — and joins what is left. Filtering
            // after the dig is what that blank check is.
            let id = identity::of_paths(&aggregate.identified_by, args).ok_or_else(|| {
                refusal_wording::render(
                    "NotFound",
                    "creating_no_identity",
                    &[("command", command_name), ("aggregate", aggregate_name), ("identity", &reading)],
                )
            })?;
            // A SECOND CREATION IS NOT A FRESH ONE — the same check the
            // "acts on an existing" branch below already makes to FIND a
            // record, made here to REFUSE one. A branch and box number are a
            // small, finite set a caller can collide with by mistake in a
            // way a minted reference cannot.
            if self.record_exists(aggregate_name, &id) {
                let offered = format!("{id:?}");
                return Err(refusal_wording::render(
                    "AlreadyExists",
                    "creating_duplicate",
                    &[
                        ("command", command_name),
                        ("aggregate", aggregate_name),
                        ("identity", &reading),
                        ("offered", &offered),
                    ],
                ));
            }
            return Ok((id, defaults_for(aggregate, &self.admitted_sets)?));
        }

        let reference_key = command
            .references
            .as_deref()
            .map(crate::naming::reference_key)
            .unwrap_or_default();
        // Validate the identity argument even when the command did not declare
        // that field as payload, matching the Ruby dispatcher before it unwraps
        // the identity for lookup.
        //
        // ONLY A PATH THAT NAMES NO FIELD, which is Ruby's rule and not an
        // accident of this one being written against a single path.
        // `Identity#from` digs a dotted path and hands back what it dug — a
        // caller may pass the SCALAR straight over, so `name: "pizza-ghost"`
        // against `identified_by { name.value }` is a lookup that finds
        // nothing, not a malformed PizzaName. Coercing it here made Rust refuse
        // the payload where Ruby refuses the record, and parity said so.
        // A dotless path (`bluebook_id`) has no field to dig, so its head IS
        // the value and Ruby coerces it against the declared attribute.
        for path in &aggregate.identified_by {
            let (head, field) = identity::split(path);
            if field.is_some() {
                continue;
            }
            let Some(value) = args.get(head) else { continue };
            if let Some(attribute) = aggregate.attributes.iter().find(|a| a.name == head) {
                coerce_attribute(aggregate, attribute, value, &self.admitted_sets)?;
            }
        }

        // A COMMAND THAT ACTS ON A RECORD MAY NAME IT BY THE ID IT DERIVED.
        // Derivation first, then the id itself, then the reference key a
        // command reaches through — Ruby's three, in Ruby's order. The
        // fallbacks are whole ids already resolved (a walk that just declared
        // one, a saga carrying it forward), so they are read as they arrive
        // rather than dug: there is no path left to follow inside an answer.
        let whole = |key: &str| -> Option<String> {
            args.get(key).map(query_text).filter(|id| !id.is_empty())
        };
        let id = identity::of_paths(&aggregate.identified_by, args)
            .or_else(|| whole("id"))
            .or_else(|| whole(&reference_key))
            .ok_or_else(|| {
                refusal_wording::render(
                    "NotFound",
                    "acting_no_identity",
                    &[("command", command_name), ("aggregate", aggregate_name), ("identity", &reading)],
                )
            })?;

        if let Some(adapter) = self.adapters.get(aggregate_name) {
            let state = adapter.find(&id).map(value_bridge::from_state).ok_or_else(|| {
                let offered = format!("{id:?}");
                refusal_wording::render(
                    "NotFound",
                    "record_missing",
                    &[("aggregate", aggregate_name), ("identity", &reading), ("offered", &offered)],
                )
            })?;
            return Ok((id, fill_hydrate_defaults_typed(aggregate, &self.admitted_sets, state)));
        }

        let key = self
            .store
            .keys()
            .find(|key| key.ends_with(&format!("::{}#{}", aggregate_name, id)))
            .cloned()
            .ok_or_else(|| {
                let offered = format!("{id:?}");
                refusal_wording::render(
                    "NotFound",
                    "record_missing",
                    &[("aggregate", aggregate_name), ("identity", &reading), ("offered", &offered)],
                )
            })?;

        Ok((id, fill_hydrate_defaults_typed(aggregate, &self.admitted_sets, self.store[&key].clone())))
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
        if domain != self.domain.name {
            return;
        }
        // Cloned, not borrowed — begin_saga/advance_saga/end_saga each take
        // &mut self, matching the shape the old JSON read already had (a
        // detached local, not a borrow of self.ir).
        let pms = self.domain.process_managers.clone();

        for pm in &pms {
            self.begin_saga(pm, event);
            self.advance_saga(pm, event, domain);
            self.end_saga(pm, event);
        }
    }

    // A DOTTED PATH NAMES THE SCALAR FIELD, matching Ruby's own
    // `saga_correlation` — `correlates_by :"end_to_end.value"` walks the
    // payload to the one field both runtimes can render identically, rather
    // than keying a saga on a whole value object (Ruby keys on the object
    // itself, Rust on its JSON text — the two disagree unless a scalar is
    // named directly).
    fn correlation(pm: &crate::ir::ProcessManager, event: &Value) -> Option<String> {
        let field = pm.correlates_by.as_str();
        let payload = event.get("payload");
        // A LATER EVENT MAY ALREADY HOLD THE SCALAR, matching Ruby's own
        // `saga_correlation` — `reference.value` digs a value object's field
        // out of a FRESH declaration, but a downstream event this same value
        // was smuggled through as a passthrough argument carries it as a
        // scalar already, with nothing left to dig. `Value::get` on a
        // `Value::String` returns `None` rather than panicking, so without
        // this check the digger would silently stop finding the correlation
        // instead of crashing the way Ruby's did — descending only while
        // there is still an object to descend into.
        let held = field.split('.').fold(payload, |held, segment| {
            held.and_then(|v| if v.is_object() { v.get(segment) } else { Some(v) })
        });
        if let Some(value) = held {
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

        // THE STAMP — `deliver_saga_dispatch` marks its own event before this
        // saga's next step ever asks, for a leg whose command declares
        // NEITHER the correlation field itself nor the emitting aggregate's
        // own reference key (the two tiers above and below). docs/porting/
        // behavior-notes.md named the payload-only lookup "the weakest part
        // of the design" : a correlation key arriving on a command only
        // because `correlation_keys` widens the undeclared-argument allow-
        // list domain-wide. This is the additive fix — a leg that carries
        // nothing correlation-shaped at all still correlates, because the
        // saga that dispatched it already knows the answer. Keyed by the
        // correlation HEAD rather than a bare scalar so an event stamped by
        // one saga cannot be misread by an unrelated one.
        let root = field.split('.').next().unwrap_or(field);
        if let Some(stamped) = event
            .get("correlation")
            .and_then(|c| c.get(root))
            .and_then(Value::as_str)
        {
            if !stamped.is_empty() {
                return Some(stamped.to_string());
            }
        }

        // A SELF-REFERENCING LEG carries the correlation forward under ITS
        // OWN reference key ("wire", "transfer") — matching Ruby's own
        // `saga_correlation` — not under whatever the correlates_by field
        // happens to be called. Constant across every self-referencing
        // command on the tracked aggregate, and never a false match for an
        // unrelated aggregate's event: a command addresses by its OWN
        // declared identity path first, never by `reference_key`, so nothing
        // is found here for an event that does not belong to this saga.
        let own_key = event
            .get("aggregate")
            .and_then(Value::as_str)
            .map(crate::naming::reference_key)
            .unwrap_or_default();
        let value = event
            .get("payload")
            .and_then(|payload| payload.get(&own_key))
            .and_then(Value::as_str)
            .unwrap_or_default();
        if value.is_empty() {
            None
        } else {
            Some(value.to_string())
        }
    }

    fn begin_saga(&mut self, pm: &crate::ir::ProcessManager, event: &Value) {
        let name = pm.name.clone();
        let event_name = event
            .get("name")
            .and_then(Value::as_str)
            .unwrap_or_default();
        if event_name != pm.starts_on {
            return;
        }

        let Some(correlation) = Self::correlation(pm, event) else {
            let field = pm.correlates_by.as_str();
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

        let first_state = pm.states.first().cloned().unwrap_or_default();
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

    fn advance_saga(&mut self, pm: &crate::ir::ProcessManager, event: &Value, domain: &str) {
        let pm_name = pm.name.clone();
        let event_name = event
            .get("name")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string();
        let Some(handler) = pm
            .handlers
            .iter()
            .find(|h| h.event_type == event_name)
            .cloned()
        else {
            return;
        };
        let Some(correlation) = Self::correlation(pm, event) else {
            return;
        };

        let from = handler.from_state.clone();
        let to = handler.to_state.clone();

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

        let dispatches = handler.dispatches.clone();
        for spec in &dispatches {
            self.deliver_saga_dispatch(pm, spec, event, &memory, &correlation, domain);
        }
    }

    fn deliver_saga_dispatch(
        &mut self,
        pm: &crate::ir::ProcessManager,
        spec: &crate::ir::DispatchSpec,
        event: &Value,
        memory: &Map<String, Value>,
        correlation: &str,
        domain: &str,
    ) {
        let command = spec.command_name.as_str();
        let payload = event
            .get("payload")
            .and_then(Value::as_object)
            .cloned()
            .unwrap_or_default();

        // THE HEAD OF THE DOTTED PATH, not `correlates_by` itself — a
        // different question, matching `IR::ProcessManager#correlation_head`
        // on the Ruby side. `correlates_by` says which scalar a FRESH event
        // correlates on (dug through a value object's dot). This says what a
        // DOWNSTREAM DISPATCH is allowed to call the already-resolved scalar
        // it carries forward — a plain identifier, never a value object, so
        // it never needed the dot. Same `identity::split` head-taking
        // `correlation_keys` already uses — reuse, not a second derivation.
        let correlates_head = identity::split(&pm.correlates_by).0.to_string();
        let mut args = Map::new();
        for (key, token) in &spec.with_spec {
            let value = match token.strip_prefix(':') {
                Some(name) if name == correlates_head => Value::String(correlation.to_string()),
                Some(name) => payload
                    .get(name)
                    .or_else(|| memory.get(name))
                    .cloned()
                    .unwrap_or(Value::Null),
                None => parse_literal(token),
            };
            args.insert(key.clone(), value);
        }

        let target = if command.contains("::") {
            command.to_string()
        } else {
            format!("{domain}::{command}")
        };
        let mut record = json!({
            "process_manager": pm.name, "instance": correlation, "dispatch": command,
        });

        let outcome = if self.reaction_depth >= MAX_REACTION_DEPTH {
            Err(format!("reaction depth {MAX_REACTION_DEPTH} reached"))
        } else {
            self.reaction_depth += 1;
            // Saved and restored around this call, not just set : a leg's own
            // event can recursively trigger a DIFFERENT saga's dispatch (a
            // different correlation) before `self.dispatch` returns here, and
            // that inner call must not leave its correlation stamped on
            // whatever this call's own remaining `emits` still have to
            // announce.
            let previous_correlation = self.pending_correlation.take();
            self.pending_correlation = Some((correlates_head.clone(), correlation.to_string()));
            let result = self.dispatch(&target, &args);
            self.pending_correlation = previous_correlation;
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
            self.unwind_saga(pm, event, memory, correlation, domain);
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
        pm: &crate::ir::ProcessManager,
        event: &Value,
        memory: &Map<String, Value>,
        correlation: &str,
        domain: &str,
    ) {
        let Some(handler) = pm.handlers.iter().find(|h| h.event_type == REFUSED).cloned() else {
            return;
        };

        let from = handler.from_state.clone();
        let to = handler.to_state.clone();
        let state = self
            .saga_instances
            .get(&pm.name)
            .and_then(|table| table.get(correlation))
            .map(|instance| instance.0.clone())
            .unwrap_or_default();

        if state != from {
            self.sagas.push(json!({
                "process_manager": pm.name, "on": REFUSED, "instance": correlation,
                "advanced": false, "reason": format!("in {state:?}, not {from:?}"),
            }));
            return;
        }

        if let Some(instance) = self
            .saga_instances
            .get_mut(&pm.name)
            .and_then(|table| table.get_mut(correlation))
        {
            instance.0 = to.clone();
        }
        self.sagas.push(json!({
            "process_manager": pm.name, "on": REFUSED, "instance": correlation,
            "advanced": true, "from": from, "to": to,
        }));

        let dispatches = handler.dispatches.clone();
        for spec in &dispatches {
            self.deliver_saga_dispatch(pm, spec, event, memory, correlation, domain);
        }
    }

    fn end_saga(&mut self, pm: &crate::ir::ProcessManager, event: &Value) {
        let name = pm.name.clone();
        let event_name = event
            .get("name")
            .and_then(Value::as_str)
            .unwrap_or_default();
        if Some(event_name) != pm.ends_on.as_deref() {
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
        if domain != self.domain.name {
            return Vec::new();
        }
        let Some(name) = event.get("name").and_then(Value::as_str) else {
            return Vec::new();
        };
        let emitting = event
            .get("aggregate")
            .and_then(Value::as_str)
            .map(crate::naming::demodulise)
            .unwrap_or_default();

        self.domain
            .policies
            .iter()
            .filter_map(|policy| {
                if policy.event_name() != name {
                    return None;
                }
                if policy.event_qualifier().is_some_and(|aggregate| aggregate != emitting) {
                    return None;
                }

                let target_domain = policy.target_domain.as_deref().unwrap_or(domain);

                Some((policy.name.clone(), format!("{target_domain}::{}", policy.trigger_command)))
            })
            .collect()
    }

    /// What a process manager correlates by is ROUTING, not description. A saga
    /// threads its correlation key through every leg it dispatches so the event
    /// each leg emits carries it and the next step can be correlated — so the key
    /// arrives on commands that never declare it, and legitimately.
    ///
    /// THE HEAD, not the full dotted `correlates_by` — matching
    /// `IR::ProcessManager#correlation_head`. The allowed argument name is
    /// the plain identifier a `with:` value carries the already-resolved
    /// scalar under, never the dotted path used to dig a fresh event's
    /// payload.
    fn correlation_keys(&self, domain: &str) -> Vec<String> {
        if domain != self.domain.name {
            return Vec::new();
        }
        self.domain
            .process_managers
            .iter()
            .map(|pm| identity::split(&pm.correlates_by).0.to_string())
            .collect()
    }

    /// A REFERENCE IS AN ID, SO AN OBJECT IS NOT ONE.
    ///
    /// Nothing coerces a reference — `coerce_attribute` misses on
    /// "Reference<Account>", which is no value object's name, and hands the
    /// argument straight through. That is why the wrapped form went unnoticed for
    /// as long as it did: there was nowhere it could be refused, so whatever the
    /// first caller wrote became the shape.
    ///
    /// `Value.refuse_object_reference` is the same sentence on the Ruby side, and
    /// it has to be the SAME sentence — refusal wording is byte-exact contract.
    /// An Array is deliberately not refused: a reference is never a list, and a
    /// rule for a shape the language cannot declare is decoration.
    fn refuse_object_references(
        &self,
        domain: &str,
        command: &crate::ir::Command,
        args: &State,
    ) -> Result<(), String> {
        for attribute in &command.attributes {
            let Some(target) = attribute
                .r#type
                .strip_prefix("Reference<")
                .and_then(|held| held.strip_suffix('>'))
            else {
                continue;
            };
            if !args.get(&attribute.name).map(Value::is_object).unwrap_or(false) {
                continue;
            }

            let known_by = self.known_by(domain, target);
            return Err(refusal_wording::render(
                "TypeMismatch",
                "reference_as_object",
                &[("command", &command.name), ("attribute", &attribute.name), ("known_by", &known_by)],
            ));
        }
        Ok(())
    }

    /// "(Account is known by number)" — what to send instead. No article, on
    /// purpose: "an Account" and "a Customer" differ by the target's first
    /// letter, and both runtimes would have to agree on that rule to keep the
    /// refusal byte-identical. The HEADS of the identity paths, because that is
    /// what Ruby's `identity_heads` answers and what a caller passes — all of
    /// them, since a target known by two facts and named by one tells the
    /// caller to send something that would still not address it. Silent when
    /// there is nothing declared to name, the way Ruby's guard is.
    fn known_by(&self, domain: &str, target: &str) -> String {
        let Ok(aggregate) = self.find_aggregate_typed(domain, target, "") else {
            return String::new();
        };
        let heads = identity::heads_of_paths(&aggregate.identified_by);
        if heads.is_empty() {
            return String::new();
        }

        format!(" ({target} is known by {})", heads.join(", "))
    }

    // ── the typed lookups — M6b's replacement for the JSON find_* cluster
    // that used to live here (find_aggregate/find_entity/find_command/
    // find_entity_command/find_query/find_entity_query, each backed by
    // `cached_lookup` over `self.ir`). Every caller has moved to these, so
    // that cluster and its cache are gone — `resolved_cache` went with it.
    // Entities/commands/queries aren't separately cached — see
    // `typed_aggregate_cache`'s own doc comment on `Runtime` for why.

    fn find_aggregate_typed(
        &self,
        domain: &str,
        name: &str,
        verb: &str,
    ) -> Result<Arc<crate::ir::Aggregate>, String> {
        let key = format!("{domain}:{name}");
        if let Some(hit) = self.typed_aggregate_cache.borrow().get(&key) {
            return Ok(hit.clone());
        }
        // A booted Runtime holds exactly one domain, so this is a name
        // MATCH check, not a lookup among several — but a caller can still
        // pass the wrong one (a verb naming a different domain than what
        // booted), and that has to refuse the same way find_domain's JSON
        // path does, not silently fall through to "no such aggregate".
        if domain != self.domain.name {
            let domain_shown = format!("{domain:?}");
            return Err(refusal_wording::render(
                "UnknownVerb",
                "no_domain",
                &[("domain", &domain_shown), ("verb", verb)],
            ));
        }
        let Some(found) = self.domain.aggregates.iter().find(|a| a.name == name) else {
            let name_shown = format!("{name:?}");
            return Err(refusal_wording::render(
                "UnknownVerb",
                "no_aggregate",
                &[("domain", domain), ("aggregate", &name_shown)],
            ));
        };
        let resolved = Arc::new(found.clone());
        self.typed_aggregate_cache.borrow_mut().insert(key, resolved.clone());
        Ok(resolved)
    }

    fn find_entity_typed(
        aggregate: &crate::ir::Aggregate,
        entity_name: &str,
    ) -> Result<Arc<crate::ir::Entity>, String> {
        aggregate
            .entities
            .iter()
            .find(|e| e.name == entity_name)
            .map(|e| Arc::new(e.clone()))
            .ok_or_else(|| {
                let entity_shown = format!("{entity_name:?}");
                refusal_wording::render(
                    "UnknownVerb",
                    "entity_unknown",
                    &[("aggregate", aggregate.name.as_str()), ("entity", &entity_shown)],
                )
            })
    }

    fn find_command_typed(aggregate: &crate::ir::Aggregate, name: &str) -> Option<Arc<crate::ir::Command>> {
        aggregate.commands.iter().find(|c| c.name == name).map(|c| Arc::new(c.clone()))
    }

    fn find_entity_command_typed(
        entity: &crate::ir::Entity,
        command_name: &str,
    ) -> Result<Arc<crate::ir::Command>, String> {
        entity
            .commands
            .iter()
            .find(|c| c.name == command_name)
            .map(|c| Arc::new(c.clone()))
            .ok_or_else(|| {
                let command_shown = format!("{command_name:?}");
                refusal_wording::render(
                    "UnknownVerb",
                    "entity_no_command",
                    &[("entity", entity.name.as_str()), ("command", &command_shown)],
                )
            })
    }

    fn find_query_typed(
        aggregate: &crate::ir::Aggregate,
        query_name: &str,
    ) -> Result<Arc<crate::ir::Query>, String> {
        aggregate
            .queries
            .iter()
            .find(|q| q.name == query_name)
            .map(|q| Arc::new(q.clone()))
            .ok_or_else(|| {
                let query_shown = format!("{query_name:?}");
                refusal_wording::render(
                    "UnknownVerb",
                    "no_query",
                    &[("aggregate", aggregate.name.as_str()), ("query", &query_shown)],
                )
            })
    }

    fn find_entity_query_typed(
        entity: &crate::ir::Entity,
        query_name: &str,
    ) -> Result<Arc<crate::ir::Query>, String> {
        entity
            .queries
            .iter()
            .find(|q| q.name == query_name)
            .map(|q| Arc::new(q.clone()))
            .ok_or_else(|| {
                let query_shown = format!("{query_name:?}");
                refusal_wording::render(
                    "UnknownVerb",
                    "entity_query_missing",
                    &[("entity", entity.name.as_str()), ("query", &query_shown)],
                )
            })
    }
}

fn parse_verb(verb: &str) -> Result<(String, String, String), String> {
    let (domain, aggregate, command) = crate::naming::split_verb(verb).ok_or_else(|| {
        let verb_shown = format!("{verb:?}");
        refusal_wording::render("UnknownVerb", "not_fully_qualified", &[("verb", &verb_shown)])
    })?;

    Ok((
        domain.to_string(),
        aggregate.to_string(),
        command.to_string(),
    ))
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

    /// Loading existing state runs the same default-fill a fresh
    /// instance gets — a declared default the record predates fills in;
    /// a stored value is never overwritten; an attribute with no default
    /// stays exactly as stored. Mirrors Ruby's
    /// `Instance.hydrate_with_defaults` (spec/hydrate_defaults_spec.rb).
    #[test]
    fn hydrating_stored_state_fills_declared_defaults_only() {
        fn attribute(name: &str, r#type: &str, default: Option<&str>, list: bool) -> crate::ir::Attribute {
            crate::ir::Attribute {
                name: name.to_string(),
                r#type: r#type.to_string(),
                default: default.map(str::to_string),
                list,
                optional: false,
                enum_values: vec![],
                pattern: None,
                admits: None,
            }
        }
        fn value_object(name: &str, attributes: Vec<crate::ir::Attribute>) -> crate::ir::ValueObject {
            crate::ir::ValueObject { name: name.to_string(), attributes, invariants: vec![], members: vec![], closed_set: false }
        }

        let aggregate = crate::ir::Aggregate {
            name: "Account".to_string(),
            description: None,
            identified_by: vec![],
            attributes: vec![
                attribute("balance", "Money", None, false),
                // Ruby-hash-literal declaration text, the same shape
                // `parse_literal` reads any other declared default through.
                attribute("standing", "Standing", Some("{value: \"good\"}"), false),
                attribute("notes", "Note", None, true),
            ],
            lifecycle: Some(crate::ir::Lifecycle { field: "status".to_string(), default: "open".to_string(), transitions: vec![] }),
            commands: vec![],
            queries: vec![],
            value_objects: vec![
                value_object("Money", vec![attribute("cents", "Integer", None, false)]),
                value_object("Standing", vec![attribute("value", "String", None, false)]),
                value_object("Note", vec![attribute("text", "String", None, false)]),
            ],
            entities: vec![],
        };
        let admitted_sets = HashMap::new();

        let mut stored = Map::new();
        stored.insert("balance".to_string(), json!({ "cents": 100 }));
        let filled = fill_hydrate_defaults_typed(&aggregate, &admitted_sets, stored);
        assert_eq!(filled.get("standing"), Some(&json!({ "value": "good" })));
        assert_eq!(filled.get("notes"), Some(&json!([])));
        assert_eq!(filled.get("status"), Some(&json!("open")));
        assert_eq!(filled.get("balance"), Some(&json!({ "cents": 100 })));

        let mut stored = Map::new();
        stored.insert("standing".to_string(), json!({ "value": "delinquent" }));
        stored.insert("status".to_string(), json!("closed"));
        let filled = fill_hydrate_defaults_typed(&aggregate, &admitted_sets, stored);
        assert_eq!(filled.get("standing"), Some(&json!({ "value": "delinquent" })));
        assert_eq!(filled.get("status"), Some(&json!("closed")));
        assert_eq!(filled.get("balance"), None);
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
    // reference) usable in gt/gte/lt/lte at all — the actual gap this closes:
    // every comparator banking declares (Overdrawn, HighBalance,
    // StrictlyAbove, AtMost) takes its bound as a kwarg, so a literal number
    // still never reaches this path through the real corpus. Exercised here
    // directly instead.
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


    /// An adapter that answers `query` with whatever it was told to, so the
    /// CANDIDATES contract can be tested from the caller's side.
    struct NarrowingAdapter {
        records: HashMap<String, AggregateState>,
        answer: Option<Vec<String>>,
    }

    impl NarrowingAdapter {
        fn holding(ids: &[&str], answer: Option<Vec<String>>) -> Self {
            let mut records = HashMap::new();
            for id in ids {
                let mut state = AggregateState::new(id);
                // Every row is "open", so the declared where matches ALL of them
                // and any difference in the answer comes from the candidate set.
                state.set("status", crate::runtime::Value::Str("open".into()));
                records.insert(id.to_string(), state);
            }
            Self { records, answer }
        }
    }

    impl PersistenceAdapter for NarrowingAdapter {
        fn find(&self, id: &str) -> Option<&AggregateState> { self.records.get(id) }
        fn find_mut(&mut self, id: &str) -> Option<&mut AggregateState> { self.records.get_mut(id) }
        fn all(&self) -> Vec<&AggregateState> { self.records.values().collect() }
        fn count(&self) -> usize { self.records.len() }
        fn save(&mut self, state: AggregateState, _ctx: WriteContext<'_>) -> Result<(), String> {
            self.records.insert(state.id.clone(), state);
            Ok(())
        }
        fn delete(&mut self, id: &str, _ctx: WriteContext<'_>) -> Result<(), String> {
            self.records.remove(id);
            Ok(())
        }
        fn query(&self, _wheres: &[crate::ir::WhereClause], _attrs: &HashMap<String, String>) -> Option<Vec<AggregateState>> {
            self.answer.as_ref().map(|ids| {
                ids.iter().filter_map(|id| self.records.get(id).cloned()).collect()
            })
        }
        fn seed_record(&mut self, state: AggregateState) { self.records.insert(state.id.clone(), state); }
    }

    fn answered_with(answer: Option<Vec<String>>) -> Vec<String> {
        let mut runtime = Runtime::boot("../examples/banking/bluebook/banking.bluebook").unwrap();
        runtime.adapters.insert(
            "Account".to_string(),
            Box::new(NarrowingAdapter::holding(&["a", "b", "c"], answer)),
        );

        runtime
            .query("Banking::Account.Open", &State::new())
            .unwrap()
            .into_iter()
            .filter_map(|row| row.get("id").and_then(Value::as_str).map(str::to_string))
            .collect()
    }

    // THE POST-FILTER IS AUTHORITATIVE, and these four say so from both sides.
    //
    // An adapter that cannot narrow, one that narrows exactly, and one that
    // narrows too little all give the SAME answer — which is the whole reason
    // the contract can be "superset" rather than "exact", and why a partial
    // pushdown is safe.
    #[test]
    fn an_adapter_that_cannot_narrow_answers_as_it_always_did() {
        assert_eq!(answered_with(None), vec!["a", "b", "c"]);
    }

    #[test]
    fn an_exact_candidate_set_answers_the_same() {
        assert_eq!(
            answered_with(Some(vec!["a".into(), "b".into(), "c".into()])),
            vec!["a", "b", "c"]
        );
    }

    #[test]
    fn an_over_broad_candidate_set_answers_the_same() {
        // Deliberately unnarrowed, repeated — the filter still decides.
        assert_eq!(
            answered_with(Some(vec!["c".into(), "a".into(), "b".into()])),
            vec!["a", "b", "c"]
        );
    }

    // AND THIS IS WHY THE CONTRACT SAYS SUPERSET. An adapter that returns too
    // FEW rows changes the answer, and nothing downstream can put them back —
    // the filter can only remove. Under-returning is the one failure a candidate
    // set can commit, which is why `build_pushdown` emits nothing rather than
    // guess whenever it cannot express a clause exactly.
    #[test]
    fn an_under_broad_candidate_set_loses_rows_that_should_have_matched() {
        assert_eq!(answered_with(Some(vec!["a".into()])), vec!["a"]);
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
    }

    #[test]
    fn boot_repairs_a_mirror_that_missed_an_authoritative_append() {
        let mut state = AggregateState::new("a");
        state.set("balance", crate::runtime::Value::Int(500));
        let primary = JournalAdapter {
            records: HashMap::from([("a".to_string(), state.clone())]),
            entries: vec![ReplicationEntry { operation: "save".to_string(), id: "a".to_string(), state: Some(state), mirrors: vec!["Sqlite".to_string()] }],
        };
        // An empty domain: this test drives mirror recovery, which reads no
        // declarations at all.
        let mut runtime = Runtime::new(crate::ir::Domain {
            name: "Test".to_string(),
            vision: None,
            classification: None,
            version: None,
            aggregates: vec![],
            policies: vec![],
            process_managers: vec![],
            read_models: vec![],
        });
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
                "refuse_absent_arguments",
                "normalize_args",
                "resolve_references",
                "hydrate",
                "enforce_givens",
                "admissible_transition",
                "assign_creation_attributes",
                "apply_mutations",
                "advance_lifecycle",
                "enforce_ensures",
                "save",
                "emit",
            ]
        );
    }

// THE SAME SENTENCE, IN THE OTHER RUNTIME.
//
// Refusal wording is byte-exact contract — bin/parity diffs it character
// for character — and the only mechanism this repo has for holding two
// languages to one string BELOW that level is asserting the same literal in
// both. Its twin is spec/reference_shape_spec.rb.
#[test]
fn a_wrapped_reference_is_refused_in_the_same_words_as_ruby() {
    let mut runtime = Runtime::boot("../spec/fixtures/settlement.bluebook").unwrap();

    for number in ["a", "b"] {
        let open: State =
            serde_json::from_value(json!({ "number": { "value": number } })).unwrap();
        runtime.dispatch("Wire::Drawer.Open", &open).unwrap();
    }

    let asked: State = serde_json::from_value(json!({
        "reference": {"value": "w1"},
        "amount": {"cents": 100},
        "source": {"value": "a"},
        "destination": "b"
    }))
    .unwrap();

    assert_eq!(
        runtime.dispatch("Wire::Wire.Ask", &asked).unwrap_err(),
        "Ask refused — a reference is an id, and source arrived as an object (Drawer is known by number)"
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

        // ADDRESSED BY ITS LABEL, the way the Ruby twin addresses it
        // (vocabulary_conformance_spec.rb). A Widget is `identified_by
        // { label.value }`, so it is stored as "x" — passing `id: "w1"`
        // opened one widget and then looked for another, and the entity
        // leg has been refusing "no Widget with label" ever since the
        // fixture learned to name a field. Nothing minted, nothing guessed.
        let open: State = serde_json::from_value(json!({
            "label": {"value": "x"},
            "amount": {"value": 5},
            "part_sequence": {"value": 1},
            "part_note": {"value": "start"}
        }))
        .unwrap();
        runtime.dispatch("DispatchOrder::Widget.Open", &open).unwrap();

        runtime.dispatch_trace = Some(Vec::new());
        let advance: State = serde_json::from_value(json!({
            "label": {"value": "x"},
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
                "enforce_ensures",
                "save",
                "emit",
            ]
        );
    }
}

#[cfg(test)]
mod correlation_stamp_tests {
    use super::*;

    // `correlation`'s payload tier and own-key fallback are exercised by the
    // ExternalSettlement/Settlement corpus already. This is the THIRD tier —
    // stamped by `deliver_saga_dispatch` via `pending_correlation` when a
    // leg's own command declares neither the correlation field itself nor
    // anything the payload/own-key lookups above can reach. Reached only
    // when both prior tiers find nothing, and keyed by correlation HEAD so
    // an event stamped by one saga can't be misread by an unrelated one.
    #[test]
    fn correlates_on_a_stamp_when_neither_prior_tier_finds_anything() {
        let pm = crate::ir::ProcessManager {
            name: String::new(),
            correlates_by: "code.value".to_string(),
            starts_on: String::new(),
            ends_on: None,
            states: Vec::new(),
            handlers: Vec::new(),
        };
        let event = json!({
            "aggregate": "Alarm",
            "id": "evt-2",
            "payload": { "label": { "value": "backup" } },
            "correlation": { "code": "smoke-1" }
        });

        assert_eq!(Runtime::correlation(&pm, &event), Some("smoke-1".to_string()));
    }

    #[test]
    fn a_stamp_under_a_different_head_is_not_read_as_this_pm_s_own() {
        let pm = crate::ir::ProcessManager {
            name: String::new(),
            correlates_by: "code.value".to_string(),
            starts_on: String::new(),
            ends_on: None,
            states: Vec::new(),
            handlers: Vec::new(),
        };
        let event = json!({
            "aggregate": "Alarm",
            "id": "evt-2",
            "payload": {},
            "correlation": { "wire": "wire-1" }
        });

        assert_eq!(Runtime::correlation(&pm, &event), None);
    }

    // Not a unit test of `correlation` in isolation — this proves the actual
    // WIRING: `deliver_saga_dispatch` sets `pending_correlation`,
    // `stamp_pending_correlation` reaches the right event copy, and
    // `self.events` (what `bin/run`'s dump and `bin/parity` diff) stays
    // clean of it throughout. `spec/fixtures/correlation_stamp.bluebook` is
    // the Rust-side twin of `correlation_key_spec.rb`'s "a saga leg that
    // never declares the correlation key at all" — same shape, same claim.
    #[test]
    fn a_saga_leg_that_never_declares_the_key_still_ends_the_right_instance() {
        let mut runtime = Runtime::boot("../spec/fixtures/correlation_stamp.bluebook").unwrap();

        let args: State = serde_json::from_value(json!({ "code": { "value": "smoke-1" } })).unwrap();
        runtime
            .dispatch("CorrelationStamp::Sighting.Raise", &args)
            .unwrap();

        let born = runtime.sagas.iter().any(|entry| {
            entry.get("process_manager").and_then(Value::as_str) == Some("Watch")
                && entry.get("instance").and_then(Value::as_str) == Some("smoke-1")
                && entry.get("born").and_then(Value::as_bool) == Some(true)
        });
        assert!(born, "expected a born Watch instance keyed by smoke-1, got {:?}", runtime.sagas);

        let ended = runtime.sagas.iter().any(|entry| {
            entry.get("process_manager").and_then(Value::as_str) == Some("Watch")
                && entry.get("instance").and_then(Value::as_str) == Some("smoke-1")
                && entry.get("ended").and_then(Value::as_bool) == Some(true)
        });
        assert!(ended, "expected the same instance to end, got {:?}", runtime.sagas);

        // THE ARCHIVAL COPY STAYS CLEAN. `self.events` is what `bin/run`'s
        // dump and `bin/parity` diff — a `correlation` key leaking in here
        // would be an observable, comparable wire change, not the internal
        // bookkeeping detail it's meant to be.
        for event in &runtime.events {
            assert!(
                event.get("correlation").is_none(),
                "self.events must never carry a correlation field: {event:?}"
            );
        }
    }
}

#[cfg(test)]
mod typed_lookup_tests {
    use super::*;

    // Every typed find_*_typed function, proven against the same real
    // fixture dispatch_order_tests boots — not yet called by dispatch()/
    // dispatch_entity() (M6b's actual sweep), but already correct and
    // cached, ready for the callers to move over.
    #[test]
    fn find_aggregate_typed_resolves_and_caches() {
        let runtime = Runtime::boot("../spec/fixtures/dispatch_order.bluebook").unwrap();

        let first = runtime.find_aggregate_typed("DispatchOrder", "Widget", "DispatchOrder::Widget.Open").unwrap();
        assert_eq!(first.name, "Widget");

        let second = runtime.find_aggregate_typed("DispatchOrder", "Widget", "DispatchOrder::Widget.Open").unwrap();
        assert!(Arc::ptr_eq(&first, &second), "a second lookup must hit the cache, not re-scan");
    }

    #[test]
    fn find_aggregate_typed_refuses_the_wrong_domain_and_the_wrong_aggregate() {
        let runtime = Runtime::boot("../spec/fixtures/dispatch_order.bluebook").unwrap();

        let wrong_domain = runtime.find_aggregate_typed("Nonesuch", "Widget", "Nonesuch::Widget.Open").unwrap_err();
        assert!(wrong_domain.contains("no domain"), "{wrong_domain}");

        let wrong_aggregate =
            runtime.find_aggregate_typed("DispatchOrder", "Nonesuch", "DispatchOrder::Nonesuch.Open").unwrap_err();
        assert!(wrong_aggregate.contains("has no aggregate"), "{wrong_aggregate}");
    }

    #[test]
    fn find_entity_command_query_typed_resolve_a_real_piece() {
        let runtime = Runtime::boot("../spec/fixtures/dispatch_order.bluebook").unwrap();
        let aggregate = runtime.find_aggregate_typed("DispatchOrder", "Widget", "").unwrap();

        let command = Runtime::find_command_typed(&aggregate, "Open");
        assert!(command.is_some(), "Widget.Open must resolve");

        let entity = Runtime::find_entity_typed(&aggregate, "Part").unwrap();
        assert_eq!(entity.name, "Part");

        let piece_command = Runtime::find_entity_command_typed(&entity, "Advance").unwrap();
        assert_eq!(piece_command.name, "Advance");

        let missing_entity = Runtime::find_entity_typed(&aggregate, "Nonesuch").unwrap_err();
        assert!(missing_entity.contains("Widget") && missing_entity.contains("no entity"), "{missing_entity}");
    }
}
