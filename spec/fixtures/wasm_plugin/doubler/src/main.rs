//! Answers `Pluginned::Ledger.Doubled`: the `amount` argument doubled, beside the note of the
//! `entry` it references (which the runtime hands over as that record's stored state). Any other
//! question is refused, so a test can see a refusal cross the boundary too.
//!
//! The contract every plugin keeps: read one question as JSON on stdin,
//! `{"question": "Bluebook::Aggregate.Query", "args": {...}}`, and write one answer as JSON on
//! stdout, `{"rows": [...]}` or `{"refused": "why"}`.

use serde_json::{json, Value};
use std::io::{Read, Write};

fn answer(question: &str, args: &Value) -> Result<Value, String> {
    match question {
        "Pluginned::Ledger.Doubled" => {
            let amount = args["amount"].as_i64().ok_or("amount is not a whole number")?;
            Ok(json!([{ "amount": amount * 2, "note": args["entry"]["note"]["value"] }]))
        }
        _ => Err(format!("doubler does not answer {question}")),
    }
}

fn main() {
    let mut input = String::new();
    let reply = match std::io::stdin().read_to_string(&mut input).map_err(|e| e.to_string())
        .and_then(|_| serde_json::from_str::<Value>(&input).map_err(|e| e.to_string()))
    {
        Ok(asked) => match answer(asked["question"].as_str().unwrap_or(""), &asked["args"]) {
            Ok(rows) => json!({ "rows": rows }),
            Err(refusal) => json!({ "refused": refusal }),
        },
        Err(e) => json!({ "refused": format!("the question is not JSON: {e}") }),
    };
    std::io::stdout().write_all(reply.to_string().as_bytes()).unwrap();
}
