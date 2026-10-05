//! Port of the retired Ruby generator's `expr_emitter.rb`: turns each IR rule's `ast` tree into `Expr` source.
//! A literal-array `include?` never reaches here; `AstJson` rewrites it to an or of equalities.

use crate::json::Json;
use crate::naming::ruby_inspect_string;

pub fn emit_ast(node: &Json) -> String {
    let op = node.get("op").and_then(Json::as_str).unwrap_or_else(|| panic!("ast node has no string \"op\": {node:?}"));
    let sub = |key: &str| emit_ast(field(node, op, key));
    let boxed = |key: &str| format!("Box::new({})", sub(key));
    let text = |key: &str| ruby_inspect_string(field(node, op, key).as_str().unwrap_or_else(|| panic!("{op}'s {key:?} isn't a string: {node:?}")));

    match op {
        "or" => format!("Expr::Or({}, {})", boxed("left"), boxed("right")),
        "and" => format!("Expr::And({}, {})", boxed("left"), boxed("right")),
        "not" => format!("Expr::Not({})", boxed("expr")),
        "compare" => format!("Expr::Compare {{ op: {}, left: {}, right: {} }}", emit_comparison(field(node, op, "cmp")), boxed("left"), boxed("right")),
        "include" => format!("Expr::Include {{ haystack: {}, needle: {} }}", boxed("haystack"), boxed("needle")),
        "int" => format!("Expr::Int({})", field(node, op, "value").to_s()),
        "float" => format!("Expr::Float({}f64)", field(node, op, "value").to_s()),
        "str" => format!("Expr::Str({}.to_string())", text("value")),
        "bool" => format!("Expr::Bool({})", field(node, op, "value").to_s()),
        "nil" => "Expr::Nil".to_string(),
        "lookup" => format!("Expr::Lookup({})", ruby_inspect_string(&path_of(node, op).join("."))),
        "add" => format!("Expr::Add({}, {})", boxed("left"), boxed("right")),
        "sign_test" => format!("Expr::SignTest {{ op: {}, receiver: {} }}", emit_comparison(field(node, op, "cmp")), boxed("receiver")),
        "empty" => format!("Expr::Empty({})", boxed("receiver")),
        "to_s" => format!("Expr::ToS({})", boxed("receiver")),
        "modulo" => format!("Expr::Modulo {{ receiver: {}, divisor: {} }}", boxed("receiver"), boxed("divisor")),
        "size" => format!("Expr::Size({})", boxed("receiver")),
        "block_predicate" => format!(
            "Expr::BlockPredicate {{ mode: crate::kernel::BlockMode::{}, receiver: {}, param: {}, predicate: {} }}",
            block_mode(node, op),
            boxed("receiver"),
            text("param"),
            boxed("predicate")
        ),
        "find" => format!(
            "Expr::Find {{ receiver: {}, param: {}, predicate: {}, path: &[{}] }}",
            boxed("receiver"),
            text("param"),
            boxed("predicate"),
            path_of(node, op).iter().map(|segment| ruby_inspect_string(segment)).collect::<Vec<_>>().join(", ")
        ),
        "array" => format!(
            "Expr::Array(vec![{}])",
            field(node, op, "elements").each().iter().map(emit_ast).collect::<Vec<_>>().join(", ")
        ),
        "matches_regex" => format!("Expr::MatchesRegex {{ receiver: {}, pattern: {}.to_string(), flags: {}.to_string() }}", boxed("receiver"), text("pattern"), text("flags")),
        "presence" => format!("Expr::Presence {{ receiver: {}, negated: {} }}", boxed("receiver"), field(node, op, "negated").to_s()),
        "assignment" => format!("Expr::Assignment {{ receiver: {}, negated: {} }}", boxed("receiver"), field(node, op, "negated").to_s()),
        "split" => format!("Expr::Split {{ receiver: {}, separator: {}.to_string() }}", boxed("receiver"), text("separator")),
        "starts_with" => format!("Expr::StartsWith {{ receiver: {}, substring: {}.to_string() }}", boxed("receiver"), text("substring")),
        "ends_with" => format!("Expr::EndsWith {{ receiver: {}, substring: {}.to_string() }}", boxed("receiver"), text("substring")),
        "first" => format!("Expr::First({})", boxed("receiver")),
        "last" => format!("Expr::Last({})", boxed("receiver")),
        // Every op in `AstJson::OPS` has an arm above; reaching here is a hard failure.
        other => panic!("unhandled ast op {other:?} — no Rust rendering exists for it in this generator (rust/codegen/src/expr_emitter.rs#emit_ast)"),
    }
}

// Fully qualified because the self-hosted grammar declares its own `Comparison` type.
pub fn emit_comparison(cmp: &Json) -> String {
    let flag = |key: &str| cmp.get(key).unwrap_or_else(|| panic!("cmp has no {key:?}: {cmp:?}")).to_s();
    format!("crate::kernel::Comparison {{ less_than: {}, equal: {}, negated: {} }}", flag("less_than"), flag("equal"), flag("negated"))
}

fn field<'a>(node: &'a Json, op: &str, key: &str) -> &'a Json {
    node.get(key).unwrap_or_else(|| panic!("{op} node has no {key:?} field: {node:?}"))
}

fn path_of(node: &Json, op: &str) -> Vec<String> {
    field(node, op, "path")
        .each()
        .iter()
        .map(|segment| segment.as_str().map(str::to_string).unwrap_or_else(|| panic!("{op}'s path has a non-string segment: {node:?}")))
        .collect()
}

fn block_mode(node: &Json, op: &str) -> &'static str {
    match field(node, op, "mode").as_str() {
        Some("all") => "All",
        Some("any") => "Any",
        Some("none") => "None",
        other => panic!("block_predicate's mode {other:?} is none of all/any/none: {node:?}"),
    }
}
