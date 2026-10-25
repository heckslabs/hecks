//! A preview's answer for a client: whether the command would be accepted and, if not, why.
//!
//! The kernel's dry-run step answers `{verb, ok, error?, refusal?, kind?, stage?}`. This reshapes
//! it into the envelope every client reads, the one `Dispatcher#validate` gives in Ruby:
//! `{ok, refusals: [{kind, stage, refusal, message}]}`. The kernel stops at the first refusal, so
//! `refusals` holds at most one; Ruby reports every refusal of the stage it stopped in. What the
//! kernel does not know (the attribute, the path, the rule) is absent, which a client reads as null.

use serde_json::{json, Value};
use std::collections::HashMap;

/// Whether a request's query string asks for a preview instead of the command: `?dry_run=1` or
/// `?dry_run=true`.
#[allow(clippy::implicit_hasher)] // reason: the query map always comes from this crate's own default-hashed parser
pub fn requested(query: &HashMap<String, String>) -> bool {
    matches!(query.get("dry_run").map(String::as_str), Some("1" | "true"))
}

/// The dry run the kernel answered, the last one in the result.
fn dry_run(result: &Value) -> Option<&Value> {
    result.get("dry_runs")?.as_array()?.last()
}

/// Whether the previewed command would be accepted. A kernel result with no dry run answers no.
pub fn accepted(result: &Value) -> bool {
    dry_run(result)
        .and_then(|run| run.get("ok"))
        .and_then(Value::as_bool)
        .unwrap_or(false)
}

/// The envelope a client receives: `ok`, and the refusal when there is one.
pub fn answer(result: &Value) -> Value {
    let refusals: Vec<Value> = match dry_run(result) {
        Some(run) if !accepted(result) => vec![refusal(run)],
        _ => Vec::new(),
    };
    json!({ "ok": accepted(result), "refusals": refusals })
}

fn refusal(run: &Value) -> Value {
    json!({
        "kind": run.get("kind").cloned().unwrap_or_else(|| json!("refused")),
        "stage": run.get("stage").cloned().unwrap_or_else(|| json!("state")),
        "refusal": run.get("refusal").cloned().unwrap_or(Value::Null),
        "message": run.get("error").cloned().unwrap_or(Value::Null),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn refused() -> Value {
        json!({ "dry_runs": [{
            "verb": "Banking::Account.Open", "ok": false, "error": "Open refused — customer is active",
            "refusal": "GivenNotMet", "kind": "refused", "stage": "givens",
        }] })
    }

    #[test]
    fn a_query_asks_for_a_preview_with_dry_run_one_or_true_and_nothing_else() {
        let query = |value: &str| HashMap::from([("dry_run".to_string(), value.to_string())]);
        assert!(requested(&query("1")) && requested(&query("true")));
        assert!(!requested(&query("0")) && !requested(&query("")) && !requested(&HashMap::new()));
    }

    #[test]
    fn an_accepted_dry_run_answers_ok_with_no_refusals() {
        let result = json!({ "dry_runs": [{ "verb": "A::B.C", "ok": true }] });
        assert_eq!(answer(&result), json!({ "ok": true, "refusals": [] }));
    }

    #[test]
    fn a_refused_dry_run_answers_its_kind_stage_and_message() {
        assert_eq!(
            answer(&refused()),
            json!({ "ok": false, "refusals": [{
                "kind": "refused", "stage": "givens", "refusal": "GivenNotMet",
                "message": "Open refused — customer is active",
            }] })
        );
    }

    #[test]
    fn a_refusal_the_kernel_did_not_class_is_a_plain_refusal_in_the_state_stage() {
        let result = json!({ "dry_runs": [{ "verb": "A::B.C", "ok": false, "error": "boom" }] });
        let first = &answer(&result)["refusals"][0];
        assert_eq!(
            (first["kind"].as_str(), first["stage"].as_str()),
            (Some("refused"), Some("state"))
        );
    }

    #[test]
    fn a_result_with_no_dry_run_is_not_accepted() {
        assert!(!accepted(&json!({ "instances": {} })));
    }

    #[test]
    fn the_last_dry_run_is_the_answer() {
        let result = json!({ "dry_runs": [{ "ok": false, "error": "old" }, { "ok": true }] });
        assert!(accepted(&result));
    }
}
