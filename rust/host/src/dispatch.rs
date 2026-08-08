// TIES THE JOURNAL AND THE SANDBOX TOGETHER — this is the one place
// that knows both halves exist; wasm_runner and journal each stay
// ignorant of the other. `handle` is the whole rehydrate-replay
// contract in one function: read history, replay history + the new
// step, persist the new step iff the module itself accepted it.

use crate::journal;
use crate::wasm_runner;
use std::path::Path;
use tokio_postgres::Client;

pub struct Outcome {
    pub result: serde_json::Value,
    pub accepted: bool,
}

pub async fn handle(
    client: &Client,
    wasm_path: &Path,
    verb: &str,
    args: serde_json::Value,
) -> anyhow::Result<Outcome> {
    let mut steps = journal::load_steps(client).await?;
    steps.push(serde_json::json!({ "verb": verb, "args": args.clone() }));

    let input = serde_json::json!({ "steps": steps }).to_string();
    // wasm_runner::run is sync and, internally, wasmtime-wasi's p1 sync
    // bridge tries to spin up its own tokio runtime to drive the async
    // memory pipes — fatal if called directly from a thread already
    // driving one (this handler's own async runtime, or the Lambda
    // executor's). spawn_blocking moves it onto a thread with no
    // runtime of its own, where that's fine.
    let owned_wasm_path = wasm_path.to_path_buf();
    let output =
        tokio::task::spawn_blocking(move || wasm_runner::run(&owned_wasm_path, &input)).await??;
    let result: serde_json::Value = serde_json::from_str(&output)?;

    // See journal.rs's own header: every PRIOR step in this replay
    // already succeeded once, deterministically, so the only step that
    // can legitimately show up in `refusals` is the new one just
    // appended last.
    let refusals = result
        .get("refusals")
        .and_then(|r| r.as_array())
        .cloned()
        .unwrap_or_default();
    let accepted = refusals.is_empty();

    if accepted {
        journal::append(client, verb, &args).await?;
    }

    Ok(Outcome { result, accepted })
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio_postgres::NoTls;

    // A REAL, THROWAWAY POSTGRES DATABASE per test — never the real
    // dev database, same reasoning hecksagain's own
    // spec/adapters/driven/postgres_spec.rb and Embryonaut's
    // spec/adapters/embryonaut_access_control_spec.rb hold themselves
    // to. Uniquely named per test (not one shared scratch DB) so
    // `cargo test`'s default parallelism doesn't race two tests
    // against the same journal table.
    async fn scratch_db(name: &str) -> Client {
        let (admin, conn) = tokio_postgres::connect("host=localhost dbname=postgres", NoTls)
            .await
            .expect("connect to postgres");
        tokio::spawn(async move {
            let _ = conn.await;
        });
        admin
            .batch_execute(&format!("DROP DATABASE IF EXISTS {name} WITH (FORCE)"))
            .await
            .unwrap();
        admin
            .batch_execute(&format!("CREATE DATABASE {name}"))
            .await
            .unwrap();

        let (client, conn) =
            tokio_postgres::connect(&format!("host=localhost dbname={name}"), NoTls)
                .await
                .expect("connect to scratch db");
        tokio::spawn(async move {
            let _ = conn.await;
        });
        journal::ensure_schema(&client).await.unwrap();
        client
    }

    fn wasm_path() -> std::path::PathBuf {
        std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../dist/banking.wasm")
    }

    fn register(reference: &str) -> serde_json::Value {
        serde_json::json!({
            "reference": { "value": reference },
            "name": { "given": "Ada", "family": "Lovelace" },
            "email": { "address": "ada@example.com" }
        })
    }

    #[tokio::test]
    async fn accepts_and_persists_a_first_command() {
        let client = scratch_db("rust_host_dispatch_test_1").await;

        let outcome = handle(
            &client,
            &wasm_path(),
            "Banking::Customer.Register",
            register("CUST-0001"),
        )
        .await
        .unwrap();

        assert!(outcome.accepted);
        assert_eq!(outcome.result["refusals"].as_array().unwrap().len(), 0);
        let steps = journal::load_steps(&client).await.unwrap();
        assert_eq!(steps.len(), 1);
    }

    #[tokio::test]
    async fn rehydrates_prior_history_before_evaluating_the_new_command() {
        let client = scratch_db("rust_host_dispatch_test_2").await;

        let first = handle(
            &client,
            &wasm_path(),
            "Banking::Customer.Register",
            register("CUST-0001"),
        )
        .await
        .unwrap();
        assert!(
            first.accepted,
            "first registration should succeed: {:?}",
            first.result
        );

        // The SHARP proof rehydration actually happened, not just that
        // two calls each independently succeeded: registering the SAME
        // reference twice against a domain that enforces uniqueness
        // only refuses the second time if the first call's effect was
        // genuinely rebuilt from Postgres before this one ran. A store
        // that silently started empty every call (rehydration broken)
        // would let this wrongly succeed instead.
        let second = handle(
            &client,
            &wasm_path(),
            "Banking::Customer.Register",
            register("CUST-0001"),
        )
        .await
        .unwrap();

        assert!(
            !second.accepted,
            "duplicate registration should be refused, proving prior state was rehydrated: {:?}",
            second.result
        );
        let steps = journal::load_steps(&client).await.unwrap();
        assert_eq!(
            steps.len(),
            1,
            "the refused duplicate must not be persisted"
        );
    }
}
