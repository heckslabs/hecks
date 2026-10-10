//! Rust side of the stored-value differential: runs the mint audit's structural layer
//! (`reference_validate::validate`) over each `{aggregate, id, state}` case on stdin against one
//! domain IR, and prints the violations of each. `spec/rust_host_reference_validate_conformance_spec.rb`
//! holds those to the answers the Ruby runtime gives the same values.

#[allow(dead_code)]
#[path = "../expr_json.rs"]
mod expr_json;
#[allow(dead_code)]
#[path = "../reference_validate.rs"]
mod reference_validate;

use serde_json::{json, Value};
use std::io::Read;

// Usage: `validate_harness < {"ir": <domain ir.json>, "cases": [{"aggregate": "Name", "id": "x", "state": {..}}, ..]}`.
// Prints `{"results": [{"violations": [..]} | {"error": ".."}, ..]}`, one per case, in order.
fn main() -> anyhow::Result<()> {
    let mut input = String::new();
    std::io::stdin().read_to_string(&mut input)?;
    let request: Value = serde_json::from_str(&input)?;
    let ir = request.get("ir").ok_or_else(|| anyhow::anyhow!("no \"ir\" on stdin"))?;
    let cases = request.get("cases").and_then(Value::as_array).ok_or_else(|| anyhow::anyhow!("no \"cases\" array on stdin"))?;

    let results: Vec<Value> = cases.iter().map(|case| answer(ir, case)).collect();
    println!("{}", json!({ "results": results }));
    Ok(())
}

fn answer(ir: &Value, case: &Value) -> Value {
    let name = case.get("aggregate").and_then(Value::as_str).unwrap_or("");
    let aggregate = ir
        .get("aggregates")
        .and_then(Value::as_array)
        .and_then(|list| list.iter().find(|a| a.get("name").and_then(Value::as_str) == Some(name)));
    match aggregate {
        None => json!({ "error": format!("no aggregate {name:?} in the IR") }),
        Some(aggregate) => {
            let id = case.get("id").and_then(Value::as_str).unwrap_or("");
            json!({ "violations": reference_validate::validate(ir, aggregate, id, &case["state"]) })
        }
    }
}
