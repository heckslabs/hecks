//! Rust side of the expression differential: interprets each `{ast, instance}` case on stdin
//! through the same `expr_json` the mint-time invariant checker uses, and prints one result each.
//! `spec/rust_host_expr_json_conformance_spec.rb` diffs those against Ruby's own interpreters.

#[allow(dead_code)]
#[path = "../expr_json.rs"]
mod expr_json;

use expr_json::Value;
use serde_json::{json, Value as Json};
use std::io::Read;

// Usage: `expr_harness < {"cases": [{"ast": <ast_json>, "instance": <json>}, ...]}`.
// Prints `{"results": [{"ok": <value>} | {"error": <message>}, ...]}`, one per case, in order.
fn main() -> anyhow::Result<()> {
    let mut input = String::new();
    std::io::stdin().read_to_string(&mut input)?;
    let request: Json = serde_json::from_str(&input)?;
    let cases = request.get("cases").and_then(Json::as_array).ok_or_else(|| anyhow::anyhow!("no \"cases\" array on stdin"))?;

    let results: Vec<Json> = cases
        .iter()
        .map(|case| {
            let outcome = expr_json::parse(&case["ast"]).and_then(|expr| expr_json::interpret(&expr, &case["instance"]));
            match outcome {
                Ok(value) => json!({ "ok": to_json(&value) }),
                Err(error) => json!({ "error": error }),
            }
        })
        .collect();

    println!("{}", json!({ "results": results }));
    Ok(())
}

fn to_json(value: &Value) -> Json {
    match value {
        Value::Int(i) => json!(i),
        Value::Float(f) => serde_json::Number::from_f64(*f).map_or(Json::Null, Json::Number),
        Value::Str(s) => json!(s),
        Value::Bool(b) => json!(b),
        Value::Nil => Json::Null,
        Value::Array(items) => Json::Array(items.iter().map(to_json).collect()),
        Value::Object(object) => object.clone(),
    }
}
