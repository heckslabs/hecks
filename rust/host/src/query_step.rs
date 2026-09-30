//! The wire's query step: `{"query": "Aggregate.Query", "args": {...}}`.
//!
//! A declared query that filters stored records is answered by the kernel against current
//! state, the way the Ruby launcher and doors answer it. A query that `returns` a value object
//! is answered from outside the domain (a hecksagon `answers_query` binding); this host binds
//! no adapter, so it refuses that question rather than answer it from the aggregate's rows, and
//! it writes nothing to the journal for either.

use crate::dispatch;
use serde_json::{json, Value};
use std::path::Path;
use tokio::sync::Mutex;
use tokio_postgres::Client;

/// What the step should do with a question, decided from the domain's IR alone.
#[derive(Debug, PartialEq)]
pub enum Plan {
    /// Ask the kernel this qualified question (`Domain::Aggregate.Query`).
    Kernel(String),
    /// Refuse with this kind and message; the kernel is never invoked.
    Refuse { kind: &'static str, message: String },
}

/// Decides how a question is answered.
///
/// @param domain_ir the domain's IR, when this host has one (`HECKS_IR_PATH`)
/// @param domain the domain's name, used to qualify a short question
/// @param question `Aggregate.Query`, or `Domain::Aggregate.Query`
/// @return a kernel question for a declared derivable query, a refusal for an unknown query on a
///   known aggregate or for a query answered outside the domain
pub fn plan(domain_ir: Option<&Value>, domain: &str, question: &str) -> Plan {
    let short = question.rsplit_once("::").map_or(question, |(_, rest)| rest);
    let qualified = format!("{domain}::{short}");
    let Some((aggregate_name, query_name)) = short.split_once('.') else {
        return Plan::Kernel(qualified);
    };
    let aggregate = domain_ir
        .and_then(|ir| ir.get("aggregates"))
        .and_then(|v| v.as_array())
        .and_then(|all| all.iter().find(|a| a.get("name").and_then(|v| v.as_str()) == Some(aggregate_name)));
    // An aggregate or an entity query this IR does not show is the kernel's to refuse.
    let Some(aggregate) = aggregate else { return Plan::Kernel(qualified) };
    if query_name.contains('.') {
        return Plan::Kernel(qualified);
    }
    let declared = aggregate
        .get("queries")
        .and_then(|v| v.as_array())
        .and_then(|all| all.iter().find(|q| q.get("name").and_then(|v| v.as_str()) == Some(query_name)));
    match declared {
        None => Plan::Refuse { kind: "UnknownVerb", message: format!("{aggregate_name} has no query {query_name:?}") },
        Some(query) if query.get("returns").is_some_and(|r| !r.is_null()) => Plan::Refuse {
            kind: "WiringError",
            message: format!(
                "no adapter answers {short} in this host: it is answered outside the domain, \
                 and the Rust host binds no adapter — nothing can answer {short}"
            ),
        },
        Some(_) => Plan::Kernel(qualified),
    }
}

/// The kernel's own shape for a refused query: a `queries` entry with null rows and a top-level
/// refusal, with nothing seeded or written.
pub fn refusal_result(question: &str, args: &Value, kind: &str, message: &str) -> Value {
    json!({
        "instances": {},
        "events": [],
        "refusals": [{ "verb": question, "error": message, "kind": kind }],
        "queries": [{ "query": question, "args": args, "rows": null, "error": message }],
    })
}

/// Answers one query step.
///
/// @param body the wire body, carrying `query` and optionally `args`
/// @return the kernel's result for a derivable query, or a refusal-shaped result
pub async fn answer(
    body: &Value,
    domain_ir: Option<&Value>,
    domain: &str,
    client: &Mutex<Client>,
    wasm_path: &Path,
) -> Result<Value, String> {
    let question = body.get("query").and_then(|v| v.as_str()).ok_or("\"query\" must name a question")?;
    let args = body.get("args").cloned().unwrap_or_else(|| json!({}));
    match plan(domain_ir, domain, question) {
        Plan::Kernel(qualified) => dispatch::query(client, wasm_path, &qualified, args).await.map_err(|e| format!("{e:#}")),
        Plan::Refuse { kind, message } => Ok(refusal_result(question, &args, kind, &message)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn domain() -> Value {
        json!({ "name": "Banking", "aggregates": [{
            "name": "Ledger",
            "queries": [
                { "name": "Open", "attributes": [] },
                { "name": "Ir", "attributes": [], "returns": "Document" },
                { "name": "Rows", "attributes": [], "returns": "list_of(Row)" }
            ]
        }]})
    }

    #[test]
    fn a_declared_derivable_query_goes_to_the_kernel_qualified() {
        let ir = domain();
        assert_eq!(plan(Some(&ir), "Banking", "Ledger.Open"), Plan::Kernel("Banking::Ledger.Open".into()));
        assert_eq!(plan(Some(&ir), "Banking", "Banking::Ledger.Open"), Plan::Kernel("Banking::Ledger.Open".into()));
    }

    #[test]
    fn a_query_that_returns_a_value_object_is_refused_as_answered_outside_the_domain() {
        let ir = domain();
        for question in ["Ledger.Ir", "Banking::Ledger.Rows"] {
            let Plan::Refuse { kind, message } = plan(Some(&ir), "Banking", question) else { panic!("{question} not refused") };
            assert_eq!(kind, "WiringError");
            assert!(message.contains("answered outside the domain"), "{message}");
            assert!(message.ends_with(&format!("nothing can answer {}", question.rsplit("::").next().unwrap())), "{message}");
        }
    }

    #[test]
    fn an_undeclared_query_on_a_known_aggregate_is_refused_as_ruby_words_it() {
        assert_eq!(
            plan(Some(&domain()), "Banking", "Ledger.Nope"),
            Plan::Refuse { kind: "UnknownVerb", message: "Ledger has no query \"Nope\"".into() }
        );
    }

    #[test]
    fn what_this_ir_does_not_show_is_left_to_the_kernel() {
        let ir = domain();
        assert_eq!(plan(Some(&ir), "Banking", "Ghost.Open"), Plan::Kernel("Banking::Ghost.Open".into()));
        assert_eq!(plan(Some(&ir), "Banking", "Ledger.Entry.All"), Plan::Kernel("Banking::Ledger.Entry.All".into()));
        assert_eq!(plan(None, "Banking", "Ledger.Ir"), Plan::Kernel("Banking::Ledger.Ir".into()));
    }

    #[test]
    fn a_refusal_carries_the_kernels_own_shape_and_no_rows() {
        let result = refusal_result("Ledger.Ir", &json!({}), "WiringError", "nope");
        assert_eq!(result["queries"][0]["rows"], Value::Null);
        assert_eq!(result["refusals"][0]["kind"], "WiringError");
        assert_eq!(result["events"], json!([]));
    }
}
