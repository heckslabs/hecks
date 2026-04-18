//! Canonical IR dump — JSON shape that both Ruby and Rust must agree on.
//!
//! This is the parity contract. Hand-written so the JSON shape is chosen
//! explicitly, not accidentally derived from Rust struct field names or
//! serde defaults. When the Ruby BluebookModel serializer (canonical_ir.rb)
//! produces the same shape, both parsers can be diffed deterministically.
//!
//! Shape:
//!   { name, category, vision, aggregates[], policies[], fixtures[], vows[] }
//!
//! Each Aggregate, Command, Attribute, etc. has a fixed key order and
//! omits no fields (uses null where absent). Stable field naming —
//! `attributes[*].type` (not Rust's internal `attr_type`),
//! `references[*].target`, etc. — so the contract reads naturally.
//!
//! Usage:
//!   hecks-life dump path/to/foo.bluebook
//!   # → JSON to stdout, exit 0

use crate::ir::{
    Aggregate, Attribute, Command, Domain, Fixture, Given, Lifecycle, Mutation,
    MutationOp, Policy, Query, Reference, Transition, ValueObject,
};
use serde_json::{json, Value};

pub fn dump(domain: &Domain) -> Value {
    json!({
        "name": domain.name,
        "category": domain.category,
        "vision": domain.vision,
        "aggregates": domain.aggregates.iter().map(dump_aggregate).collect::<Vec<_>>(),
        "policies": domain.policies.iter().map(dump_policy).collect::<Vec<_>>(),
        "fixtures": domain.fixtures.iter().map(dump_fixture).collect::<Vec<_>>(),
    })
}

fn dump_aggregate(agg: &Aggregate) -> Value {
    json!({
        "name": agg.name,
        "description": agg.description,
        "attributes": agg.attributes.iter().map(dump_attribute).collect::<Vec<_>>(),
        "value_objects": agg.value_objects.iter().map(dump_value_object).collect::<Vec<_>>(),
        "references": agg.references.iter().map(dump_reference).collect::<Vec<_>>(),
        "commands": agg.commands.iter().map(dump_command).collect::<Vec<_>>(),
        "queries": agg.queries.iter().map(dump_query).collect::<Vec<_>>(),
        "lifecycle": agg.lifecycle.as_ref().map(dump_lifecycle),
    })
}

fn dump_attribute(attr: &Attribute) -> Value {
    json!({
        "name": attr.name,
        "type": attr.attr_type,
        "list": attr.list,
        "default": attr.default,
    })
}

fn dump_value_object(vo: &ValueObject) -> Value {
    json!({
        "name": vo.name,
        "description": vo.description,
        "attributes": vo.attributes.iter().map(dump_attribute).collect::<Vec<_>>(),
    })
}

fn dump_reference(r: &Reference) -> Value {
    json!({
        "name": r.name,
        "target": r.target,
        "domain": r.domain,
    })
}

fn dump_command(cmd: &Command) -> Value {
    json!({
        "name": cmd.name,
        "description": cmd.description,
        "role": cmd.role,
        "emits": cmd.emits,
        "attributes": cmd.attributes.iter().map(dump_attribute).collect::<Vec<_>>(),
        "references": cmd.references.iter().map(dump_reference).collect::<Vec<_>>(),
        "givens": cmd.givens.iter().map(dump_given).collect::<Vec<_>>(),
        "mutations": cmd.mutations.iter().map(dump_mutation).collect::<Vec<_>>(),
    })
}

fn dump_query(q: &Query) -> Value {
    json!({
        "name": q.name,
        "description": q.description,
    })
}

fn dump_given(g: &Given) -> Value {
    json!({
        "expression": g.expression,
        "message": g.message,
    })
}

fn dump_mutation(m: &Mutation) -> Value {
    json!({
        "field": m.field,
        "op": dump_mutation_op(&m.operation),
        "value": normalize_value(&m.value),
    })
}

// Strip whitespace adjacent to brackets/braces/parens. Source representations
// differ ("[ a, b ]" vs "[a, b]") even when semantically identical; both
// runtimes normalize so the canonical output agrees.
fn normalize_value(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut in_str = false;
    let mut prev = '\0';
    let chars: Vec<char> = s.chars().collect();
    for (i, &c) in chars.iter().enumerate() {
        match c {
            '"' if prev != '\\' => { in_str = !in_str; out.push(c); }
            ' ' | '\t' if !in_str => {
                let next = chars.get(i + 1).copied().unwrap_or('\0');
                let just_after_open = matches!(prev, '[' | '{' | '(');
                let just_before_close = matches!(next, ']' | '}' | ')');
                if !just_after_open && !just_before_close { out.push(c); }
            }
            _ => out.push(c),
        }
        prev = c;
    }
    out
}

fn dump_mutation_op(op: &MutationOp) -> &'static str {
    match op {
        MutationOp::Set       => "set",
        MutationOp::Append    => "append",
        MutationOp::Increment => "increment",
        MutationOp::Decrement => "decrement",
        MutationOp::Toggle    => "toggle",
    }
}

fn dump_lifecycle(lc: &Lifecycle) -> Value {
    json!({
        "field": lc.field,
        "default": lc.default,
        "transitions": lc.transitions.iter().map(dump_transition).collect::<Vec<_>>(),
    })
}

fn dump_transition(t: &Transition) -> Value {
    json!({
        "command": t.command,
        "to_state": t.to_state,
        "from_state": t.from_state,
    })
}

fn dump_policy(p: &Policy) -> Value {
    json!({
        "name": p.name,
        "on_event": p.on_event,
        "trigger_command": p.trigger_command,
        "target_domain": p.target_domain,
    })
}

fn dump_fixture(f: &Fixture) -> Value {
    // Use array of [key, value] pairs to preserve order — same shape Ruby will emit.
    let pairs: Vec<Value> = f.attributes.iter()
        .map(|(k, v)| json!([k, normalize_value(v)]))
        .collect();
    json!({
        "aggregate_name": f.aggregate_name,
        "attributes": pairs,
    })
}

