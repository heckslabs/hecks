// Facts a command `needs` (ADR 0081): the host answers them before the kernel reads the arguments,
// the way the Ruby interpreter does in `decode_arguments`. The command's own IR carries
// `"needs": [{"fact": "now"}]`; a needed fact the caller left out is filled with the clock's
// answer, a supplied one is kept. The answer is written into the arguments before they are
// journaled, so a replay re-dispatches the recorded value rather than asking the clock again.

use serde_json::{json, Value};
use std::sync::atomic::{AtomicI64, Ordering};

/// What answers the `now` fact: epoch seconds, UTC.
pub trait Clock {
    fn now_secs(&self) -> i64;
}

/// The wall clock.
pub struct SystemClock;

impl Clock for SystemClock {
    fn now_secs(&self) -> i64 {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs() as i64)
            .unwrap_or_default()
    }
}

/// A clock that always answers one moment, for tests.
#[cfg(test)]
pub struct FixedClock(pub i64);

#[cfg(test)]
impl Clock for FixedClock {
    fn now_secs(&self) -> i64 {
        self.0
    }
}

const UNSET: i64 = i64::MIN;
static OVERRIDE: AtomicI64 = AtomicI64::new(UNSET);

/// Makes the process clock answer `secs` until `clear_fixed_clock`; for tests only.
#[cfg(test)]
pub fn set_fixed_clock(secs: i64) {
    OVERRIDE.store(secs, Ordering::SeqCst);
}

#[cfg(test)]
pub fn clear_fixed_clock() {
    OVERRIDE.store(UNSET, Ordering::SeqCst);
}

/// The process clock the dispatcher uses: the wall clock unless a test has fixed it.
pub struct ProcessClock;

impl Clock for ProcessClock {
    fn now_secs(&self) -> i64 {
        match OVERRIDE.load(Ordering::SeqCst) {
            UNSET => SystemClock.now_secs(),
            fixed => fixed,
        }
    }
}

/// The command's declared needs, each with the type of the attribute of the same name.
fn declared_needs<'a>(domain_ir: &'a Value, verb: &str) -> Vec<(&'a str, Option<&'a str>)> {
    let Some((qualified_aggregate, command_name)) = verb.rsplit_once('.') else { return Vec::new() };
    let aggregate = qualified_aggregate.rsplit("::").next().unwrap_or(qualified_aggregate);
    let named = |value: &Value, name: &str| value.get("name").and_then(Value::as_str) == Some(name);
    let list = |value: &'a Value, key: &str| -> Vec<&'a Value> {
        value.get(key).and_then(Value::as_array).map(|a| a.iter().collect()).unwrap_or_default()
    };
    let mut needs = Vec::new();
    for command in list(domain_ir, "aggregates")
        .into_iter()
        .filter(|a| named(a, aggregate))
        .flat_map(|a| list(a, "commands"))
        .filter(|c| named(c, command_name))
    {
        let attributes = list(command, "attributes");
        for fact in list(command, "needs").into_iter().filter_map(|n| n.get("fact").and_then(Value::as_str)) {
            let attribute_type =
                attributes.iter().find(|a| named(a, fact)).and_then(|a| a.get("type")).and_then(Value::as_str);
            needs.push((fact, attribute_type));
        }
    }
    needs
}

/// Every command's needs as the kernel's input `"needs"` reads them: `{ verb: [{fact, type}] }`.
/// The kernel answers a reaction's command from this (it has no IR of its own), and the same
/// step's `occurred_at` keeps the answer the same on replay.
pub fn table(domain_ir: &Value) -> Value {
    let domain = domain_ir.get("name").and_then(Value::as_str).unwrap_or_default();
    let mut verbs = serde_json::Map::new();
    let aggregates = domain_ir.get("aggregates").and_then(Value::as_array).into_iter().flatten();
    for aggregate in aggregates {
        let aggregate_name = aggregate.get("name").and_then(Value::as_str).unwrap_or_default();
        for command in aggregate.get("commands").and_then(Value::as_array).into_iter().flatten() {
            let command_name = command.get("name").and_then(Value::as_str).unwrap_or_default();
            let verb = format!("{domain}::{aggregate_name}.{command_name}");
            let needs: Vec<Value> = declared_needs(domain_ir, &verb)
                .into_iter()
                .map(|(fact, attribute_type)| json!({"fact": fact, "type": attribute_type.unwrap_or("")}))
                .collect();
            if !needs.is_empty() {
                verbs.insert(verb, Value::Array(needs));
            }
        }
    }
    Value::Object(verbs)
}

fn list<'a>(value: &'a Value, key: &str) -> &'a [Value] {
    value.get(key).and_then(Value::as_array).map(Vec::as_slice).unwrap_or(&[])
}

fn named(value: &Value, name: &str) -> bool {
    value.get("name").and_then(Value::as_str) == Some(name)
}

/// The command a verb names: `Domain::Aggregate.Command` on the aggregate itself, or
/// `Domain::Aggregate.Entity[.Entity].Command` on an entity nested inside it.
fn command_for<'a>(domain_ir: &'a Value, verb: &str) -> Option<&'a Value> {
    let mut segments = verb.split('.');
    let aggregate = segments.next()?.rsplit("::").next()?;
    let mut path: Vec<&str> = segments.collect();
    let command_name = path.pop()?;
    let mut node = list(domain_ir, "aggregates").iter().find(|a| named(a, aggregate))?;
    for entity in path {
        node = list(node, "entities").iter().find(|e| named(e, entity))?;
    }
    list(node, "commands").iter().find(|c| named(c, command_name))
}

/// The command's attributes that declare a default (`attribute :runs, Count, default: 30`), each
/// with the declared value. An attribute whose default is null declares none.
fn declared_defaults<'a>(domain_ir: &'a Value, verb: &str) -> Vec<(&'a str, &'a Value)> {
    let Some(command) = command_for(domain_ir, verb) else { return Vec::new() };
    list(command, "attributes")
        .iter()
        .filter_map(|a| {
            let default = a.get("default").filter(|d| !d.is_null())?;
            Some((a.get("name").and_then(Value::as_str)?, default))
        })
        .collect()
}

/// Every command's declared defaults as the kernel's input `"defaults"` reads them:
/// `{ verb: { attribute: value } }`, entity commands included. The kernel fills a reaction's
/// command from this the same way the host fills the outermost one.
pub fn defaults_table(domain_ir: &Value) -> Value {
    let domain = domain_ir.get("name").and_then(Value::as_str).unwrap_or_default();
    let mut verbs = serde_json::Map::new();
    for aggregate in list(domain_ir, "aggregates") {
        let aggregate_name = aggregate.get("name").and_then(Value::as_str).unwrap_or_default();
        collect_defaults(domain_ir, aggregate, &format!("{domain}::{aggregate_name}"), &mut verbs);
    }
    Value::Object(verbs)
}

/// Adds the defaults of `node`'s commands, then of each entity nested in it, under `prefix`.
fn collect_defaults(domain_ir: &Value, node: &Value, prefix: &str, verbs: &mut serde_json::Map<String, Value>) {
    for command in list(node, "commands") {
        let command_name = command.get("name").and_then(Value::as_str).unwrap_or_default();
        let verb = format!("{prefix}.{command_name}");
        let defaults: serde_json::Map<String, Value> =
            declared_defaults(domain_ir, &verb).into_iter().map(|(name, value)| (name.to_string(), value.clone())).collect();
        if !defaults.is_empty() {
            verbs.insert(verb, Value::Object(defaults));
        }
    }
    for entity in list(node, "entities") {
        let entity_name = entity.get("name").and_then(Value::as_str).unwrap_or_default();
        collect_defaults(domain_ir, entity, &format!("{prefix}.{entity_name}"), verbs);
    }
}

/// The facts of a command invocation: the `with` object when the call carries one, else the
/// flat object itself (the kernel's `CommandInvocation` reads both shapes).
fn facts_mut(args: &mut Value) -> Option<&mut serde_json::Map<String, Value>> {
    if args.get("with").is_some_and(Value::is_object) {
        return args.get_mut("with").and_then(Value::as_object_mut);
    }
    args.as_object_mut()
}

fn answer(fact: &str, attribute_type: Option<&str>, clock: &dyn Clock) -> Option<Value> {
    match fact {
        "now" => {
            let secs = clock.now_secs();
            Some(if attribute_type == Some("Integer") { json!(secs) } else { json!({ "value": secs }) })
        }
        _ => None,
    }
}

/// Fills each fact `verb` needs that `args` leaves out, before any gate reads the arguments. A key
/// the caller supplied (even a null) is kept; a command that needs nothing is untouched.
pub fn fill_needs(domain_ir: &Value, verb: &str, args: &mut Value, clock: &dyn Clock) {
    let needs = declared_needs(domain_ir, verb);
    if needs.is_empty() {
        return;
    }
    let Some(facts) = facts_mut(args) else { return };
    for (fact, attribute_type) in needs {
        if facts.contains_key(fact) {
            continue;
        }
        if let Some(value) = answer(fact, attribute_type, clock) {
            facts.insert(fact.to_string(), value);
        }
    }
}

/// Gives each argument `verb` declares a default for, and `args` leaves out, that default, after
/// `fill_needs` and before any gate reads the arguments. A key the caller supplied (even a null)
/// is kept, as is a fact `fill_needs` already answered.
pub fn fill_defaults(domain_ir: &Value, verb: &str, args: &mut Value) {
    let defaults = declared_defaults(domain_ir, verb);
    if defaults.is_empty() {
        return;
    }
    let Some(facts) = facts_mut(args) else { return };
    for (name, value) in defaults {
        if !facts.contains_key(name) {
            facts.insert(name.to_string(), value.clone());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const LEASE_IR: &str = include_str!("../../src/generated/lease_clock/ir.json");

    fn lease_ir() -> Value {
        serde_json::from_str(LEASE_IR).unwrap()
    }

    // A command whose `now` is an Integer attribute, as QualityControl's are.
    fn integer_ir() -> Value {
        json!({"name": "Qc", "aggregates": [{"name": "Check", "commands": [
            {"name": "Run", "attributes": [{"name": "now", "type": "Integer"}], "needs": [{"fact": "now"}]},
            {"name": "Plain", "attributes": [{"name": "now", "type": "Integer"}], "needs": []}
        ]}]})
    }

    fn first_needing(ir: &Value) -> String {
        ir["aggregates"]
            .as_array()
            .unwrap()
            .iter()
            .flat_map(|a| {
                a["commands"].as_array().unwrap().iter().filter(|c| !c["needs"].as_array().unwrap().is_empty()).map(
                    move |c| format!("{}::{}.{}", ir["name"].as_str().unwrap(), a["name"].as_str().unwrap(), c["name"].as_str().unwrap()),
                )
            })
            .next()
            .expect("the lease_clock domain declares a command that needs :now")
    }

    #[test]
    fn a_needed_fact_the_caller_left_out_is_filled_from_the_clock() {
        let ir = lease_ir();
        let mut args = json!({"with": {"holder": "a"}});
        fill_needs(&ir, &first_needing(&ir), &mut args, &FixedClock(1_700_000_000));
        assert_eq!(args["with"]["now"], json!({"value": 1_700_000_000}));
        assert_eq!(args["with"]["holder"], "a");
    }

    #[test]
    fn a_flat_invocation_is_filled_at_its_top_level() {
        let ir = lease_ir();
        let mut args = json!({"holder": "a"});
        fill_needs(&ir, &first_needing(&ir), &mut args, &FixedClock(5));
        assert_eq!(args["now"], json!({"value": 5}));
    }

    #[test]
    fn a_value_the_caller_supplied_is_kept() {
        let ir = lease_ir();
        let mut args = json!({"with": {"now": {"value": 42}}});
        fill_needs(&ir, &first_needing(&ir), &mut args, &FixedClock(7));
        assert_eq!(args["with"]["now"], json!({"value": 42}));
    }

    #[test]
    fn a_command_with_no_needs_is_untouched() {
        let ir = integer_ir();
        let mut args = json!({"with": {"x": 1}});
        fill_needs(&ir, "Qc::Check.Plain", &mut args, &FixedClock(7));
        assert_eq!(args, json!({"with": {"x": 1}}));
        let mut unknown = json!({"with": {}});
        fill_needs(&ir, "Qc::Check.Nope", &mut unknown, &FixedClock(7));
        assert_eq!(unknown, json!({"with": {}}));
    }

    #[test]
    fn an_integer_attribute_gets_a_bare_integer_and_an_instant_a_value_object() {
        let mut integer = json!({"with": {}});
        fill_needs(&integer_ir(), "Qc::Check.Run", &mut integer, &FixedClock(9));
        assert_eq!(integer["with"]["now"], json!(9));
        let ir = lease_ir();
        let mut instant = json!({"with": {}});
        fill_needs(&ir, &first_needing(&ir), &mut instant, &FixedClock(9));
        assert_eq!(instant["with"]["now"], json!({"value": 9}));
    }

    #[test]
    fn the_kernel_table_lists_only_commands_that_need_something() {
        let table = table(&integer_ir());
        assert_eq!(table, json!({"Qc::Check.Run": [{"fact": "now", "type": "Integer"}]}));
        assert_eq!(super::table(&json!({"name": "D"})), json!({}));
    }

    #[test]
    fn the_process_clock_answers_a_fixed_moment_and_otherwise_the_wall_clock() {
        set_fixed_clock(123);
        assert_eq!(ProcessClock.now_secs(), 123);
        clear_fixed_clock();
        assert!(ProcessClock.now_secs() > 1_700_000_000);
    }

    // A command with one defaulted attribute, one plain, and one whose default is null.
    fn defaulted_ir() -> Value {
        json!({"name": "Qc", "aggregates": [{"name": "Check", "commands": [
            {"name": "Start", "attributes": [
                {"name": "ref", "type": "Ref", "default": null},
                {"name": "runs", "type": "Count", "default": 30},
                {"name": "note", "type": "String", "default": null}
            ], "needs": []}
        ]}]})
    }

    #[test]
    fn an_omitted_argument_is_filled_with_its_declared_default() {
        let mut args = json!({"with": {"ref": {"value": "a"}}});
        fill_defaults(&defaulted_ir(), "Qc::Check.Start", &mut args);
        assert_eq!(args["with"]["runs"], 30);
        assert!(args["with"].get("note").is_none(), "a null default declares none");
    }

    #[test]
    fn a_flat_invocation_gets_its_defaults_at_its_top_level() {
        let mut args = json!({"ref": {"value": "a"}});
        fill_defaults(&defaulted_ir(), "Qc::Check.Start", &mut args);
        assert_eq!(args["runs"], 30);
    }

    #[test]
    fn a_supplied_argument_is_kept_even_when_null() {
        let mut args = json!({"runs": null});
        fill_defaults(&defaulted_ir(), "Qc::Check.Start", &mut args);
        assert!(args["runs"].is_null());
        let mut args = json!({"runs": {"value": 7}});
        fill_defaults(&defaulted_ir(), "Qc::Check.Start", &mut args);
        assert_eq!(args["runs"], json!({"value": 7}));
    }

    #[test]
    fn a_command_that_declares_no_default_is_untouched() {
        let mut args = json!({"with": {}});
        fill_defaults(&integer_ir(), "Qc::Check.Run", &mut args);
        assert_eq!(args, json!({"with": {}}));
    }

    #[test]
    fn the_kernel_table_lists_each_command_that_declares_a_default() {
        assert_eq!(defaults_table(&defaulted_ir()), json!({"Qc::Check.Start": {"runs": 30}}));
        assert_eq!(defaults_table(&integer_ir()), json!({}));
    }

    // A board entity with a defaulted command, and a card nested inside it with another.
    fn nested_ir() -> Value {
        json!({"name": "Np", "aggregates": [{"name": "Workspace", "commands": [], "entities": [
            {"name": "Board", "commands": [
                {"name": "Retitle", "attributes": [
                    {"name": "label", "type": "BoardLabel", "default": {"value": "untitled"}}], "needs": []}
            ], "entities": [
                {"name": "Card", "commands": [
                    {"name": "Remark", "attributes": [
                        {"name": "note", "type": "CardNote", "default": {"text": "none"}}], "needs": []}
                ]}
            ]}
        ]}]})
    }

    #[test]
    fn an_entity_command_is_filled_from_its_own_declared_default() {
        let mut args = json!({"reference": {"value": "W1"}, "number": {"value": 1}});
        fill_defaults(&nested_ir(), "Np::Workspace.Board.Retitle", &mut args);
        assert_eq!(args["label"], json!({"value": "untitled"}));
    }

    #[test]
    fn a_command_on_an_entity_nested_in_an_entity_is_filled_too() {
        let mut args = json!({"with": {"reference": {"value": "W1"}}});
        fill_defaults(&nested_ir(), "Np::Workspace.Board.Card.Remark", &mut args);
        assert_eq!(args["with"]["note"], json!({"text": "none"}));
    }

    #[test]
    fn an_entity_path_that_names_nothing_is_left_untouched() {
        let mut args = json!({"number": 1});
        fill_defaults(&nested_ir(), "Np::Workspace.Shelf.Retitle", &mut args);
        fill_defaults(&nested_ir(), "Np::Workspace.Board.Remark", &mut args);
        assert_eq!(args, json!({"number": 1}));
    }

    #[test]
    fn the_kernel_table_lists_entity_commands_under_their_full_path() {
        assert_eq!(
            defaults_table(&nested_ir()),
            json!({
                "Np::Workspace.Board.Retitle": {"label": {"value": "untitled"}},
                "Np::Workspace.Board.Card.Remark": {"note": {"text": "none"}}
            })
        );
    }
}
