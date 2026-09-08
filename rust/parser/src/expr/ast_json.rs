//! Mirror of `lib/hecks/bluebook/expression/ast_json.rb` — walks the
//! `Evaluator`/`Resolver` tree this module's own `parse` produces and
//! emits the SAME `"op"`-tagged JSON every Ruby rule row carries as
//! `ast`. Key order per node matches the Ruby file's Hash literal order
//! exactly, because parser parity compares the pretty-printed document
//! byte for byte — a reordered key is a parity failure, by design.
//!
//! The literal-array `include?` rewrite (OR of equalities; empty array →
//! `{"op":"bool","value":false}`) is mirrored too — see the Ruby file's
//! `emit_include` comment for the reasoning. `SignTest` drops its `test`
//! spelling in favour of the comparison triple, exactly as Ruby does.

use crate::emit::JsonValue;
use crate::expr::evaluator::{self, Evaluator};
use crate::expr::resolver::Resolver;
use crate::expr::{find_operator, Operator};

pub fn emit_predicate(canonical: &str) -> JsonValue {
    emit_bool(&evaluator::parse(canonical))
}

fn obj(pairs: Vec<(&str, JsonValue)>) -> JsonValue {
    JsonValue::Object(pairs.into_iter().map(|(k, v)| (k.to_string(), v)).collect())
}

fn op_tag(name: &str) -> (&'static str, JsonValue) {
    ("op", JsonValue::String(name.to_string()))
}

fn emit_bool(node: &Evaluator) -> JsonValue {
    match node {
        Evaluator::Or(left, right) => obj(vec![op_tag("or"), ("left", emit_bool(left)), ("right", emit_bool(right))]),
        Evaluator::And(left, right) => obj(vec![op_tag("and"), ("left", emit_bool(left)), ("right", emit_bool(right))]),
        Evaluator::Not(inner) => obj(vec![op_tag("not"), ("expr", emit_bool(inner))]),
        Evaluator::Compare { operator, left, right } => obj(vec![
            op_tag("compare"),
            ("cmp", emit_comparison(operator)),
            ("left", emit_resolver(left)),
            ("right", emit_resolver(right)),
        ]),
        Evaluator::Include { haystack, needle } => emit_include(haystack, needle),
        Evaluator::Resolve(expr) => emit_resolver(expr),
    }
}

fn emit_comparison(operator: &Operator) -> JsonValue {
    obj(vec![
        ("less_than", JsonValue::Bool(operator.compares_less_than)),
        ("equal", JsonValue::Bool(operator.compares_equal)),
        ("negated", JsonValue::Bool(operator.negated)),
    ])
}

fn emit_include(haystack: &Resolver, needle: &Resolver) -> JsonValue {
    let Resolver::ArrayLiteral(elements) = haystack else {
        return obj(vec![op_tag("include"), ("haystack", emit_resolver(haystack)), ("needle", emit_resolver(needle))]);
    };

    if elements.is_empty() {
        return obj(vec![op_tag("bool"), ("value", JsonValue::Bool(false))]);
    }

    let eq = find_operator("==");
    elements
        .iter()
        .map(|element| {
            obj(vec![
                op_tag("compare"),
                ("cmp", emit_comparison(&eq)),
                ("left", emit_resolver(needle)),
                ("right", emit_resolver(element)),
            ])
        })
        .reduce(|left, right| obj(vec![op_tag("or"), ("left", left), ("right", right)]))
        .expect("non-empty by the guard above")
}

fn emit_resolver(node: &Resolver) -> JsonValue {
    match node {
        Resolver::IntegerLiteral(v) => obj(vec![op_tag("int"), ("value", JsonValue::Number(v.to_string()))]),
        Resolver::FloatLiteral(v) => obj(vec![op_tag("float"), ("value", JsonValue::Number(ruby_float(*v)))]),
        Resolver::StringLiteral(v) => obj(vec![op_tag("str"), ("value", JsonValue::String(v.clone()))]),
        Resolver::BoolLiteral(v) => obj(vec![op_tag("bool"), ("value", JsonValue::Bool(*v))]),
        Resolver::NilLiteral => obj(vec![op_tag("nil")]),
        Resolver::Lookup(path) => obj(vec![
            op_tag("lookup"),
            ("path", JsonValue::Array(path.split('.').map(|s| JsonValue::String(s.to_string())).collect())),
        ]),
        Resolver::Addition(left, right) => obj(vec![op_tag("add"), ("left", emit_resolver(left)), ("right", emit_resolver(right))]),
        Resolver::SignTest { operator, receiver } => obj(vec![
            op_tag("sign_test"),
            ("cmp", emit_comparison(operator)),
            ("receiver", emit_resolver(receiver)),
        ]),
        Resolver::Empty(receiver) => obj(vec![op_tag("empty"), ("receiver", emit_resolver(receiver))]),
        Resolver::ToS(receiver) => obj(vec![op_tag("to_s"), ("receiver", emit_resolver(receiver))]),
        Resolver::Modulo { receiver, divisor } => obj(vec![
            op_tag("modulo"),
            ("receiver", emit_resolver(receiver)),
            ("divisor", emit_resolver(divisor)),
        ]),
        Resolver::Size(receiver) => obj(vec![op_tag("size"), ("receiver", emit_resolver(receiver))]),
        Resolver::BlockPredicate { mode, receiver, param, predicate } => obj(vec![
            op_tag("block_predicate"),
            ("mode", JsonValue::String(mode.json_name().to_string())),
            ("receiver", emit_resolver(receiver)),
            ("param", JsonValue::String(param.clone())),
            ("predicate", emit_bool(predicate)),
        ]),
        Resolver::Find { receiver, param, predicate, path } => obj(vec![
            op_tag("find"),
            ("receiver", emit_resolver(receiver)),
            ("param", JsonValue::String(param.clone())),
            ("predicate", emit_bool(predicate)),
            ("path", JsonValue::Array(path.iter().map(|s| JsonValue::String(s.clone())).collect())),
        ]),
        // Only reachable as an `include?` needle-side literal or a
        // comparison operand — the haystack case is intercepted above.
        Resolver::ArrayLiteral(elements) => obj(vec![
            op_tag("array"),
            ("elements", JsonValue::Array(elements.iter().map(emit_resolver).collect())),
        ]),
    }
}

/// Ruby's `Float#to_s` — always carries a decimal point. Mirrors
/// `rust/codegen/src/json.rs`'s own `format_number`, which this crate
/// cannot import.
fn ruby_float(n: f64) -> String {
    let text = format!("{n}");
    if text.contains('.') || text.contains('e') || text.contains('E') {
        text
    } else {
        format!("{text}.0")
    }
}
