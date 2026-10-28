//! The dispatch path against a real Postgres and the Memory store: what `rust_host_core`'s
//! dispatch does is only observable through a backend, and the backends live here.

#![allow(unused_imports)]

#[cfg(test)]
pub mod tests {

    #[test]
    fn a_command_log_line_names_the_verb_events_and_refusals_but_never_the_facts() {
        let result = serde_json::json!({
            "events": [{"name": "Registered", "data": {"email": "a@b.c"}}],
            "refusals": [{"verb": "X.Y", "error": "already exists", "kind": "AlreadyExists"}],
        });
        let fields = command_fields("Register", Some("admin"), false, &result);
        assert_eq!(fields["verb"], "Register");
        assert_eq!(fields["role"], "admin");
        assert_eq!(fields["accepted"], false);
        assert_eq!(fields["events"], serde_json::json!(["Registered"]));
        assert_eq!(fields["refusals"][0]["kind"], "AlreadyExists");
        assert!(!fields.to_string().contains("a@b.c"));
    }
    use crate::host::Host;
    use crate::journal;
    use crate::journal::LineageConfig;
    use crate::lambda_client;
    use crate::lambda_client::LambdaInvoker;
    use crate::store::journal_sql;
    use crate::store::{Accepted, DeadLetter, LineageWrite, Store, StoreExt, StoreFixtures};
    use crate::wasm_runner;
    use rust_host_core::dispatch::*;
    use std::path::Path;
    use tokio_postgres::{Client, NoTls};

    // A throwaway Postgres database per test, uniquely named so
    // `cargo test`'s default parallelism doesn't race two tests against
    // the same journal table.
    pub async fn scratch_db(name: &str) -> Store {
        let (admin, conn) = tokio_postgres::connect(&crate::test_pg::conninfo("postgres"), NoTls)
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

        let (client, conn) = tokio_postgres::connect(&crate::test_pg::conninfo(name), NoTls)
            .await
            .expect("connect to scratch db");
        tokio::spawn(async move {
            let _ = conn.await;
        });
        journal_sql::ensure_schema(&client).await.unwrap();
        crate::store::postgres_store(client)
    }

    /// An empty in-memory store, for tests that need a journal and nothing Postgres-specific.
    pub fn memory_store() -> Store {
        Store::memory(crate::store::MemoryStore::new())
    }

    /// The config a memory-backed host runs under: no era, so nothing mirrors into lineage.
    pub fn memory_config(domain: &str) -> LineageConfig {
        LineageConfig {
            domain: domain.to_string(),
            era: None,
            mirrored: None,
            seal_every: None,
        }
    }

    // Not Ruby's real provisioning — just enough structure for
    // `journal_sql::current_era` and `append_lineage_mutation` to succeed,
    // without reproducing Ruby's full DDL.
    pub async fn provision_lineage(
        client: &Client,
        domain: &str,
        era: i32,
        aggregate_storage_names: &[&str],
    ) {
        // `int`, matching Ruby's real DDL: tokio_postgres requires the
        // Rust and Postgres types to match, not just be compatible.
        client
            .batch_execute(
                "CREATE TABLE IF NOT EXISTS hecks_eras (domain text, ordinal int, held_text text)",
            )
            .await
            .unwrap();
        client
            .execute(
                "INSERT INTO hecks_eras (domain, ordinal, held_text) VALUES ($1, $2, 'test')",
                &[&domain, &era],
            )
            .await
            .unwrap();

        let journal_table = format!("hecks_journal_{}", journal_sql::snake(domain));
        client
            .batch_execute(&format!(
                "CREATE TABLE IF NOT EXISTS \"{journal_table}\" (
                    ordinal      bigserial PRIMARY KEY,
                    era          int NOT NULL,
                    aggregate    text NOT NULL,
                    aggregate_id text NOT NULL,
                    operation    text NOT NULL,
                    state        jsonb,
                    mirrors      jsonb
                )"
            ))
            .await
            .unwrap();

        for name in aggregate_storage_names {
            // Domain-qualified (ADR 0059), matching what a real write
            // targets.
            let snapshot_table = journal_sql::qualified_name(
                domain,
                &format!("{}_head_snapshot_{era}", journal_sql::snake(name)),
            );
            client
                .batch_execute(&format!(
                    "CREATE TABLE IF NOT EXISTS \"{snapshot_table}\" (id text PRIMARY KEY, ordinal bigint NOT NULL, \
                     operation text NOT NULL DEFAULT 'save', state jsonb)"
                ))
                .await
                .unwrap();
        }
    }

    // Pins a real outage: `era.is_some()` (lineage exists) and "this
    // aggregate has a mirror" are different questions. Under ADR 0034 an
    // aggregate outside the declared capable set has no head snapshot to
    // upsert into.
    #[tokio::test]
    async fn a_domain_whose_ir_declares_nothing_lineage_capable_mirrors_nothing_and_still_writes() {
        let client = scratch_db("rust_host_mirrors_nothing").await;
        {
            let guard = client.lock().await;
            // No head snapshot for Customer, as `mint` leaves an empty
            // capable set.
            guard.batch_execute("CREATE TABLE IF NOT EXISTS hecks_eras (domain text, ordinal int, held_text text)").await.unwrap();
            guard.execute("INSERT INTO hecks_eras (domain, ordinal, held_text) VALUES ('Banking', 1, 'test')", &[]).await.unwrap();
            guard
                .batch_execute(
                    "CREATE TABLE IF NOT EXISTS hecks_journal_banking (ordinal bigserial PRIMARY KEY, era int NOT NULL, \
                     aggregate text NOT NULL, aggregate_id text NOT NULL, operation text NOT NULL, state jsonb)",
                )
                .await
                .unwrap();
        }
        let wasm = wasm_path();
        let invoker = crate::lambda_client::NeverInvoker;
        let open = register("CUST-1");

        // Mirroring everything is the outage: no head snapshot exists to
        // upsert into.
        let everything = LineageConfig {
            domain: "Banking".to_string(),
            era: Some(1),
            mirrored: None,
            seal_every: None,
        };
        let refused = handle_facts(
            Host::new(&client, &wasm, &everything, &invoker),
            "Banking::Customer.Register",
            open.clone(),
            None,
        )
        .await;
        let message = match refused {
            Ok(_) => panic!("expected the missing-relation failure"),
            Err(e) => format!("{e:#}"),
        };
        assert!(
            message.contains("banking_customer_head_snapshot_1"),
            "names the relation it could not write: {message}"
        );
        assert!(
            message.contains("does not exist"),
            "carries the database's own words: {message}"
        );
        assert!(
            message.contains("Banking::Customer"),
            "names the record: {message}"
        );

        // Mirroring what the IR actually declares — nothing — writes
        // cleanly, into this crate's own journal.
        let declared = LineageConfig {
            domain: "Banking".to_string(),
            era: Some(1),
            mirrored: Some(std::collections::BTreeSet::new()),
            seal_every: None,
        };
        let outcome = handle_facts(
            Host::new(&client, &wasm, &declared, &invoker),
            "Banking::Customer.Register",
            open,
            None,
        )
        .await
        .expect("writes");
        assert!(outcome.accepted, "{}", outcome.result);

        let guard = client.lock().await;
        let journalled: i64 = guard
            .query_one("SELECT count(*) FROM hecks_lambda_journal", &[])
            .await
            .unwrap()
            .get(0);
        assert_eq!(
            journalled, 1,
            "durable in this crate's own journal, which is what `read` replays"
        );
        let mirror: Option<String> = guard
            .query_one(
                "SELECT to_regclass('banking_customer_head_snapshot_1')::text",
                &[],
            )
            .await
            .unwrap()
            .get(0);
        assert!(
            mirror.is_none(),
            "and no mirror was invented for an aggregate the IR never called capable"
        );
    }

    // The other half: an aggregate the IR does call capable is still
    // mirrored.
    #[tokio::test]
    async fn an_aggregate_the_ir_declares_capable_is_still_mirrored() {
        let client = scratch_db("rust_host_mirrors_the_capable_one").await;
        provision_lineage(&*client.lock().await, "Banking", 1, &["Customer"]).await;
        let config = LineageConfig {
            domain: "Banking".to_string(),
            era: Some(1),
            mirrored: Some(std::iter::once("Banking::Customer".to_string()).collect()),
            seal_every: None,
        };

        handle_facts(
            Host::new(
                &client,
                &wasm_path(),
                &config,
                &crate::lambda_client::NeverInvoker,
            ),
            "Banking::Customer.Register",
            register("CUST-2"),
            None,
        )
        .await
        .expect("writes");

        let guard = client.lock().await;
        let mirrored: i64 = guard
            .query_one("SELECT count(*) FROM banking_customer_head_snapshot_1", &[])
            .await
            .unwrap()
            .get(0);
        assert_eq!(mirrored, 1);
    }

    pub fn test_config(domain: &str, era: i32) -> LineageConfig {
        LineageConfig {
            domain: domain.to_string(),
            era: Some(era),
            mirrored: None,
            seal_every: None,
        }
    }

    #[test]
    fn present_hands_the_kernel_the_answer_under_present_and_answers_what_it_returns() {
        let answer = serde_json::json!({"instances": {"Shop::Item#a": {"name": {"value": "x"}}}});
        let mut sent = String::new();
        let presented = present_with(&answer, |input| {
            sent = input.to_string();
            Ok(r#"{"instances":{"Shop::Item#a":{"name":"x"}}}"#.to_string())
        })
        .unwrap();
        assert_eq!(
            serde_json::from_str::<serde_json::Value>(&sent).unwrap(),
            serde_json::json!({ "present": answer })
        );
        assert_eq!(presented["instances"]["Shop::Item#a"]["name"], "x");
    }

    #[test]
    fn present_is_an_error_when_the_kernel_fails() {
        let failed = present_with(&serde_json::json!({}), |_| {
            Ok(r#"{"error":"expected a top-level {\"steps\": [...]} object"}"#.to_string())
        });
        assert!(failed.is_err());
    }

    pub fn wasm_path() -> std::path::PathBuf {
        std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../dist/banking.wasm")
    }

    pub fn register(reference: &str) -> serde_json::Value {
        serde_json::json!({
            "reference": { "value": reference },
            "name": { "given": "Ada", "family": "Lovelace" },
            "email": { "address": "ada@example.com" }
        })
    }

    // `query` end to end through the real compiled kernel: a declared
    // query answered against whatever state the journal currently holds.
    #[tokio::test]
    async fn a_declared_query_answers_against_current_state() {
        let client = crate::dispatch_tests::tests::memory_store();
        let config = crate::dispatch_tests::tests::memory_config("Banking");

        handle(
            Host::new(&client, &wasm_path(), &config, &lambda_client::NeverInvoker),
            "Banking::Customer.Register",
            register("CUST-0100"),
            None,
        )
        .await
        .unwrap()
        .accepted
        .then_some(())
        .expect("registering a customer should succeed");

        // `Customer.Suspended` is `where status == "suspended"` — a
        // freshly registered customer is active, so the query has to
        // answer with a real, empty row set, not everything.
        let before = query(
            &client,
            &wasm_path(),
            "Banking::Customer.Suspended",
            serde_json::json!({}),
        )
        .await
        .unwrap();
        assert_eq!(before["queries"][0]["query"], "Banking::Customer.Suspended");
        assert_eq!(
            before["queries"][0]["rows"].as_array().expect("rows").len(),
            0
        );

        handle(
            Host::new(&client, &wasm_path(), &config, &lambda_client::NeverInvoker),
            "Banking::Customer.Suspend",
            serde_json::json!({ "reference": "CUST-0100", "standing": { "value": "watch" } }),
            None,
        )
        .await
        .unwrap()
        .accepted
        .then_some(())
        .expect("suspending a customer should succeed");

        let after = query(
            &client,
            &wasm_path(),
            "Banking::Customer.Suspended",
            serde_json::json!({}),
        )
        .await
        .unwrap();
        let rows = after["queries"][0]["rows"].as_array().expect("rows");
        assert_eq!(
            rows.len(),
            1,
            "the suspended customer should be the one row: {after}"
        );
        assert_eq!(rows[0]["id"], "CUST-0100");
    }

    #[tokio::test]
    async fn accepts_and_persists_a_first_command() {
        let client = scratch_db("rust_host_dispatch_test_1").await;
        provision_lineage(&*client.lock().await, "Banking", 1, &["Customer"]).await;

        let outcome = handle(
            Host::new(
                &client,
                &wasm_path(),
                &test_config("Banking", 1),
                &lambda_client::NeverInvoker,
            ),
            "Banking::Customer.Register",
            register("CUST-0001"),
            None,
        )
        .await
        .unwrap();

        assert!(outcome.accepted);
        assert_eq!(outcome.result["refusals"].as_array().unwrap().len(), 0);
        let guard = client.lock().await;
        let steps = journal_sql::load_steps(&*guard).await.unwrap();
        assert_eq!(steps.len(), 1);

        // The lineage write itself: a row landed in the era-tagged,
        // storage-name-keyed journal shape, not just the flat log above.
        let journal_rows = guard
            .query(
                "SELECT era, aggregate, aggregate_id, operation FROM hecks_journal_banking",
                &[],
            )
            .await
            .unwrap();
        assert_eq!(journal_rows.len(), 1);
        let row = &journal_rows[0];
        let era: i32 = row.get(0);
        let aggregate: String = row.get(1);
        let aggregate_id: String = row.get(2);
        let operation: String = row.get(3);
        assert_eq!(
            (
                era,
                aggregate.as_str(),
                aggregate_id.as_str(),
                operation.as_str()
            ),
            (1, "customer", "CUST-0001", "save")
        );

        // domain-qualified (docs/decisions/0059) — snake("Banking") == "banking".
        let snapshot_rows = guard
            .query("SELECT id FROM banking_customer_head_snapshot_1", &[])
            .await
            .unwrap();
        assert_eq!(
            snapshot_rows.len(),
            1,
            "the head-snapshot table should carry exactly the one live record"
        );
        let id: String = snapshot_rows[0].get(0);
        assert_eq!(id, "CUST-0001");
    }

    // The seal is part of the commit, not a tool run afterwards: the second accepted command
    // leaves a seal through the second lineage row, and the chain walks clean from it.
    #[tokio::test]
    async fn a_commit_seals_the_lineage_chain_every_so_many_rows() {
        let client = scratch_db("rust_host_dispatch_seals").await;
        provision_lineage(&*client.lock().await, "Banking", 1, &["Customer"]).await;
        let config = LineageConfig {
            seal_every: Some(2),
            ..test_config("Banking", 1)
        };

        for id in ["CUST-0001", "CUST-0002", "CUST-0003"] {
            let outcome = handle(
                Host::new(&client, &wasm_path(), &config, &lambda_client::NeverInvoker),
                "Banking::Customer.Register",
                register(id),
                None,
            )
            .await
            .unwrap();
            assert!(outcome.accepted, "{id} should be accepted");
        }

        let guard = client.lock().await;
        let seals = crate::ledger::anchors(&*guard, "Banking").await.unwrap();
        assert_eq!(
            seals.iter().map(|seal| seal.through).collect::<Vec<_>>(),
            vec![2],
            "one seal, taken by the commit that made two rows unsealed"
        );
        assert_eq!(
            crate::ledger::verify(&*guard, "Banking").await.unwrap(),
            crate::ledger::Finding::Verified(crate::ledger::Report {
                seals: 1,
                entries: 2,
                unsealed: 1
            })
        );
    }

    // Proves `occurred_at` end to end through the real wasm module: the
    // string this crate stamps and sends is the one that comes back out
    // in the returned event, not just what the in-kernel unit tests prove.
    #[tokio::test]
    async fn occurred_at_is_stamped_onto_every_returned_event_with_this_crate_s_own_real_clock() {
        let client = crate::dispatch_tests::tests::memory_store();

        let before = crate::clock::iso8601_now();
        let outcome = handle(
            Host::new(
                &client,
                &wasm_path(),
                &crate::dispatch_tests::tests::memory_config("Banking"),
                &lambda_client::NeverInvoker,
            ),
            "Banking::Customer.Register",
            register("CUST-OCCURRED-AT"),
            None,
        )
        .await
        .unwrap();
        let after = crate::clock::iso8601_now();

        assert!(outcome.accepted, "{:?}", outcome.result["refusals"]);
        let events = outcome.result["events"].as_array().unwrap();
        assert_eq!(events.len(), 1);
        let occurred_at = events[0]["occurred_at"]
            .as_str()
            .expect("occurred_at should be a real string, not null or absent");
        // Lexical comparison is valid: this format's digit-then-letter
        // layout sorts identically to chronological order for stamps
        // less than 10,000 years apart.
        assert!(
            occurred_at >= before.as_str() && occurred_at <= after.as_str(),
            "{occurred_at} should fall between {before} and {after}"
        );
    }

    #[tokio::test]
    async fn rehydrates_prior_history_before_evaluating_the_new_command() {
        let client = crate::dispatch_tests::tests::memory_store();
        let config = crate::dispatch_tests::tests::memory_config("Banking");

        let first = handle(
            Host::new(&client, &wasm_path(), &config, &lambda_client::NeverInvoker),
            "Banking::Customer.Register",
            register("CUST-0001"),
            None,
        )
        .await
        .unwrap();
        assert!(
            first.accepted,
            "first registration should succeed: {:?}",
            first.result
        );

        // Proves rehydration happened, not just that two calls each
        // succeeded independently: the second registration only refuses
        // if the first's effect was genuinely rebuilt from Postgres.
        let second = handle(
            Host::new(&client, &wasm_path(), &config, &lambda_client::NeverInvoker),
            "Banking::Customer.Register",
            register("CUST-0001"),
            None,
        )
        .await
        .unwrap();

        assert!(
            !second.accepted,
            "duplicate registration should be refused, proving prior state was rehydrated: {:?}",
            second.result
        );
        let steps = client.journal_steps().await;
        assert_eq!(
            steps.len(),
            1,
            "the refused duplicate must not be persisted"
        );
    }

    #[tokio::test]
    async fn the_snapshot_stays_current_so_nothing_replays_full_history() {
        // Direct proof (vs. the duplicate-refusal side effect above):
        // after every accepted command, replaying past the snapshot's
        // ordinal should find nothing left to replay.
        let client = scratch_db("rust_host_dispatch_test_5").await;
        provision_lineage(&*client.lock().await, "Banking", 1, &["Customer"]).await;
        let config = test_config("Banking", 1);

        for reference in ["CUST-0004", "CUST-0005", "CUST-0006"] {
            let outcome = handle(
                Host::new(&client, &wasm_path(), &config, &lambda_client::NeverInvoker),
                "Banking::Customer.Register",
                register(reference),
                None,
            )
            .await
            .unwrap();
            assert!(
                outcome.accepted,
                "registering {reference} should succeed: {:?}",
                outcome.result
            );

            let guard = client.lock().await;
            let snapshot = journal_sql::load_snapshot(&*guard)
                .await
                .unwrap()
                .expect("a snapshot should exist after the first accepted command");
            let tail = journal_sql::load_steps_after(&*guard, snapshot.ordinal)
                .await
                .unwrap();
            assert!(tail.is_empty(), "the snapshot should already reflect every accepted command, leaving nothing to replay");

            // And the seed is right, not just non-empty: it should carry
            // every customer registered so far, not just this one.
            let seeded = snapshot.seed.as_object().unwrap();
            assert!(
                seeded.keys().any(|k| k.contains(reference)),
                "the snapshot should carry the record just dispatched: {seeded:?}"
            );
        }

        let final_snapshot = journal_sql::load_snapshot(&*client.lock().await)
            .await
            .unwrap()
            .unwrap();
        let final_seed = final_snapshot.seed.as_object().unwrap();
        assert_eq!(final_seed.len(), 3, "the snapshot should accumulate all three registrations, not just the latest: {final_seed:?}");
    }

    #[test]
    fn a_top_level_error_is_a_kernel_failure_and_nothing_else_is() {
        let failed = serde_json::json!({"error": "invalid seed: Registration.status: missing from JSON args"});
        assert_eq!(
            classify(&failed),
            KernelAnswer::Failed(
                "invalid seed: Registration.status: missing from JSON args".to_string()
            )
        );
        assert_eq!(
            classify(&serde_json::json!({"error": {"code": 7}})),
            KernelAnswer::Failed("{\"code\":7}".to_string()),
            "a non-text error is still a failure"
        );

        let accepted = serde_json::json!({"instances": {}, "events": [], "refusals": []});
        assert_eq!(classify(&accepted), KernelAnswer::Accepted);

        // A refusal carries its own nested `error`; that is the module deciding,
        // not the kernel failing.
        let refused = serde_json::json!({
            "instances": {}, "events": [],
            "refusals": [{"verb": "Banking::Customer.Register", "error": "already exists", "kind": "AlreadyExists"}]
        });
        assert_eq!(classify(&refused), KernelAnswer::Refused);

        // A run whose query step failed reports it inside `queries`, still a finished run.
        let query_error = serde_json::json!({"instances": {}, "refusals": [], "queries": [{"query": "X", "rows": null, "error": "no such query"}]});
        assert_eq!(classify(&query_error), KernelAnswer::Accepted);
    }

    #[test]
    fn parse_kernel_output_turns_a_failure_into_an_error_and_keeps_refusals_as_results() {
        let error = parse_kernel_output(
            r#"{"error":"invalid seed: Customer.status: missing from JSON args"}"#,
        )
        .unwrap_err();
        assert!(
            format!("{error:#}").contains("invalid seed: Customer.status: missing from JSON args"),
            "{error:#}"
        );
        let refused = parse_kernel_output(
            r#"{"instances":{},"refusals":[{"verb":"v","error":"no","kind":"K"}]}"#,
        )
        .unwrap();
        assert_eq!(classify(&refused), KernelAnswer::Refused);
        assert!(parse_kernel_output("not json").is_err());
    }

    #[tokio::test]
    async fn a_kernel_failure_is_an_error_and_writes_nothing() {
        // Simulates a snapshot missing a field its shape now requires.
        // The kernel refuses to load it; this must fail the call and
        // leave the journal and snapshot untouched.
        let client = scratch_db("rust_host_dispatch_kernel_failure").await;
        provision_lineage(&*client.lock().await, "Banking", 1, &["Customer"]).await;
        let config = test_config("Banking", 1);
        let noinvoke = lambda_client::NeverInvoker;

        let first = handle(
            Host::new(&client, &wasm_path(), &config, &noinvoke),
            "Banking::Customer.Register",
            register("CUST-0001"),
            None,
        )
        .await
        .unwrap();
        assert!(first.accepted, "{:?}", first.result);

        let whole_world = journal_sql::load_snapshot(&*client.lock().await)
            .await
            .unwrap()
            .unwrap()
            .seed;
        let mut damaged = whole_world.clone();
        let customer = damaged
            .as_object_mut()
            .unwrap()
            .values_mut()
            .next()
            .unwrap()
            .as_object_mut()
            .unwrap();
        assert!(
            customer.remove("status").is_some(),
            "the fixture Customer carries a status"
        );
        client
            .lock()
            .await
            .execute("UPDATE hecks_lambda_snapshot SET seed = $1", &[&damaged])
            .await
            .unwrap();

        let before = snapshot_and_journal(&client).await;
        let failure = handle(
            Host::new(&client, &wasm_path(), &config, &noinvoke),
            "Banking::Customer.Register",
            register("CUST-0002"),
            None,
        )
        .await;
        let message = format!(
            "{:#}",
            failure
                .err()
                .expect("a kernel failure must be an error, not an accepted outcome")
        );
        assert!(
            message.contains("invalid seed") && message.contains("status"),
            "{message}"
        );

        assert_eq!(
            snapshot_and_journal(&client).await,
            before,
            "the failed command left the journal and the snapshot byte-identical"
        );
        assert_eq!(before.2, 1, "and only the first command was ever journaled");
        let lineage_rows: i64 = client
            .lock()
            .await
            .query_one("SELECT count(*) FROM hecks_journal_banking", &[])
            .await
            .unwrap()
            .get(0);
        assert_eq!(
            lineage_rows, 1,
            "nothing was mirrored into the era journal either"
        );

        // A read that must run the kernel over the damaged snapshot fails
        // the same way, instead of answering an empty world.
        client
            .lock()
            .await
            .execute(
                "INSERT INTO hecks_lambda_journal (verb, args) VALUES ($1, $2)",
                &[&"Banking::Customer.Register", &register("CUST-0009")],
            )
            .await
            .unwrap();
        let read_failure = read(&client, &wasm_path())
            .await
            .expect_err("a kernel failure is not an empty read");
        assert!(
            format!("{read_failure:#}").contains("invalid seed"),
            "{read_failure:#}"
        );
        let query_failure = query(
            &client,
            &wasm_path(),
            "Banking::Customer.Suspended",
            serde_json::json!({}),
        )
        .await
        .err();
        assert!(query_failure.is_some_and(|e| format!("{e:#}").contains("invalid seed")));
        client.lock().await.execute("DELETE FROM hecks_lambda_journal WHERE verb = 'Banking::Customer.Register' AND ordinal > 1", &[]).await.unwrap();

        // Once the snapshot is whole again the next command works, and the
        // snapshot afterwards holds the whole world, not just its own instance.
        client
            .lock()
            .await
            .execute(
                "UPDATE hecks_lambda_snapshot SET seed = $1",
                &[&whole_world],
            )
            .await
            .unwrap();
        let second = handle(
            Host::new(&client, &wasm_path(), &config, &noinvoke),
            "Banking::Customer.Register",
            register("CUST-0002"),
            None,
        )
        .await
        .unwrap();
        assert!(second.accepted, "{:?}", second.result);
        let after = journal_sql::load_snapshot(&*client.lock().await)
            .await
            .unwrap()
            .unwrap()
            .seed;
        let keys: Vec<&String> = after.as_object().unwrap().keys().collect();
        assert_eq!(keys.len(), 2, "the snapshot holds both customers: {keys:?}");
        assert!(
            keys.iter().any(|k| k.contains("CUST-0001"))
                && keys.iter().any(|k| k.contains("CUST-0002")),
            "{keys:?}"
        );
    }

    // The snapshot's ordinal and exact seed text, and how many commands are journaled.
    async fn snapshot_and_journal(client: &Store) -> (i64, String, i64) {
        let guard = client.lock().await;
        let snapshot = guard
            .query_one("SELECT ordinal, seed::text FROM hecks_lambda_snapshot", &[])
            .await
            .unwrap();
        let journaled: i64 = guard
            .query_one("SELECT count(*) FROM hecks_lambda_journal", &[])
            .await
            .unwrap()
            .get(0);
        (snapshot.get(0), snapshot.get(1), journaled)
    }

    #[tokio::test]
    async fn serializes_concurrent_invocations_against_the_same_journal() {
        // **The race the advisory lock closes**: without it, two concurrent
        // registrations of the same reference could both rehydrate
        // against zero prior steps, both see no conflict, and both get
        // appended — silently violating the uniqueness the domain
        // itself enforces. With the lock serializing the whole
        // read-then-append sequence, exactly one must be accepted.
        let client = crate::dispatch_tests::tests::memory_store();
        let config = crate::dispatch_tests::tests::memory_config("Banking");
        let wasm_path = wasm_path();

        let (first, second) = tokio::join!(
            handle(
                Host::new(&client, &wasm_path, &config, &lambda_client::NeverInvoker),
                "Banking::Customer.Register",
                register("CUST-0002"),
                None
            ),
            handle(
                Host::new(&client, &wasm_path, &config, &lambda_client::NeverInvoker),
                "Banking::Customer.Register",
                register("CUST-0002"),
                None
            ),
        );
        let (first, second) = (first.unwrap(), second.unwrap());

        assert_ne!(
            first.accepted, second.accepted,
            "exactly one of two concurrent duplicate registrations should be accepted: {:?} / {:?}",
            first.result, second.result
        );
        let steps = client.journal_steps().await;
        assert_eq!(
            steps.len(),
            1,
            "only the accepted registration should be persisted"
        );
    }

    #[tokio::test]
    async fn read_reflects_prior_dispatches_without_persisting_anything_new() {
        let client = crate::dispatch_tests::tests::memory_store();

        handle(
            Host::new(
                &client,
                &wasm_path(),
                &crate::dispatch_tests::tests::memory_config("Banking"),
                &lambda_client::NeverInvoker,
            ),
            "Banking::Customer.Register",
            register("CUST-0003"),
            None,
        )
        .await
        .unwrap()
        .accepted
        .then_some(())
        .expect("registration should succeed");

        let result = read(&client, &wasm_path()).await.unwrap();

        assert!(
            result["refusals"].as_array().unwrap().is_empty(),
            "a read replaying only already-accepted history should never refuse: {result:?}"
        );
        let instances = result["instances"].as_object().unwrap();
        assert!(
            instances.keys().any(|k| k.contains("CUST-0003")),
            "read should reflect the prior dispatch: {instances:?}"
        );

        // The sharp proof a read never appends: the journal is exactly
        // as long after the read as it was before it.
        let steps = client.journal_steps().await;
        assert_eq!(steps.len(), 1, "a read must never persist a journal row");
    }

    // Records every call and answers with a canned "nothing refused"
    // body, proving a cross-domain policy reaches `lambda_client::deliver`
    // with the right name/payload end to end, short of a real AWS Lambda.
    pub struct RecordingInvoker {
        calls: std::sync::Mutex<Vec<(String, String)>>,
    }

    impl RecordingInvoker {
        pub fn new() -> Self {
            Self {
                calls: std::sync::Mutex::new(Vec::new()),
            }
        }
    }

    #[async_trait::async_trait]
    impl LambdaInvoker for RecordingInvoker {
        async fn invoke(
            &self,
            function_name: &str,
            payload: &str,
        ) -> anyhow::Result<lambda_client::InvokeOutcome> {
            self.calls
                .lock()
                .unwrap()
                .push((function_name.to_string(), payload.to_string()));
            Ok(lambda_client::InvokeOutcome {
                body: serde_json::json!({ "refusals": [] }),
                function_error: false,
            })
        }
    }

    #[tokio::test]
    async fn a_cross_domain_policy_delivers_through_the_real_rehydrate_replay_path() {
        let client = crate::dispatch_tests::tests::memory_store();
        let config = crate::dispatch_tests::tests::memory_config("Banking");
        let invoker = RecordingInvoker::new();

        handle(
            Host::new(&client, &wasm_path(), &config, &invoker),
            "Banking::Customer.Register",
            register("CUST-0007"),
            None,
        )
        .await
        .unwrap()
        .accepted
        .then_some(())
        .expect("registration should succeed");

        let open_args = serde_json::json!({
            "number": { "value": "acct-freeze-me" },
            "kind": { "name": "current" },
            "daily_limit": { "cents": 50000 },
            "customer": "CUST-0007",
        });
        handle(
            Host::new(&client, &wasm_path(), &config, &invoker),
            "Banking::Account.Open",
            open_args,
            None,
        )
        .await
        .unwrap()
        .accepted
        .then_some(())
        .expect("account open should succeed");

        // `FreezeAccount` announces `AccountFrozen`, matched by
        // `ReviewOnFreeze` (`across "Compliance"`) — the real trigger
        // this feature exists for.
        let freeze_args = serde_json::json!({ "number": { "value": "acct-freeze-me" } });
        let outcome = handle(
            Host::new(&client, &wasm_path(), &config, &invoker),
            "Banking::Account.FreezeAccount",
            freeze_args,
            None,
        )
        .await
        .unwrap();
        assert!(
            outcome.accepted,
            "freeze should succeed: {:?}",
            outcome.result
        );

        let deliveries = outcome.result["cross_domain_deliveries"]
            .as_array()
            .unwrap();
        assert_eq!(
            deliveries.len(),
            1,
            "exactly one cross-domain reaction should have fired: {deliveries:?}"
        );
        assert_eq!(deliveries[0]["policy"], "ReviewOnFreeze");
        assert_eq!(deliveries[0]["target_domain"], "Compliance");
        assert_eq!(deliveries[0]["delivered"], true);

        // The same delivery also merges into "reactions"
        // ({policy, on, trigger, delivered, reason}), alongside the
        // differently-shaped "cross_domain_deliveries" entry above.
        let reactions = outcome.result["reactions"].as_array().unwrap();
        let merged = reactions
            .iter()
            .find(|r| r["policy"] == "ReviewOnFreeze")
            .expect("ReviewOnFreeze should appear in \"reactions\" too");
        assert_eq!(merged["on"], "AccountFrozen");
        assert_eq!(merged["trigger"], "Compliance::Review.Open");
        assert_eq!(merged["delivered"], true);

        {
            let calls = invoker.calls.lock().unwrap();
            assert_eq!(calls.len(), 1);
            let (function_name, payload) = &calls[0];
            assert_eq!(function_name, "hecks-compliance");
            let sent: serde_json::Value = serde_json::from_str(payload).unwrap();
            // Fully qualified, not the bare "Compliance.OpenReview":
            // generated match arms are always "Domain::Aggregate.Command",
            // and Compliance's own aggregate is named `Review`.
            assert_eq!(sent["verb"], "Compliance::Review.Open");
            assert_eq!(sent["args"]["subject_kind"], "account_freeze");
            assert_eq!(sent["args"]["subject_key"], "acct-freeze-me");
        }

        // Never re-delivered on a later replay: `pending_cross_domain`
        // only ever reads the last step's own reactions, so rehydrating
        // history here doesn't re-invoke the sibling Lambda.
        handle(
            Host::new(&client, &wasm_path(), &config, &invoker),
            "Banking::Customer.Register",
            register("CUST-0008"),
            None,
        )
        .await
        .unwrap();
        assert_eq!(
            invoker.calls.lock().unwrap().len(),
            1,
            "replaying prior history must not re-deliver its cross-domain reaction"
        );
    }

    // Pins the fix: this is the first test that reaches `check_role`
    // with a caller role actually bound and checked, not the unchecked
    // "no role at all" path every other test in this file uses.
    // `Register` requires `Some("Branch clerk")` in the generated
    // registry — real, corpus-declared.
    #[tokio::test]
    async fn a_role_gated_command_is_actually_checked_against_the_caller_role() {
        let client = crate::dispatch_tests::tests::memory_store();
        let config = crate::dispatch_tests::tests::memory_config("Banking");

        // The correct role succeeds, same as every other registration,
        // just now with a caller actually bound and matching.
        let matching = handle(
            Host::new(&client, &wasm_path(), &config, &lambda_client::NeverInvoker),
            "Banking::Customer.Register",
            register("CUST-0009"),
            Some("Branch clerk"),
        )
        .await
        .unwrap();
        assert!(
            matching.accepted,
            "the declared role should be admitted: {:?}",
            matching.result
        );

        // The actual proof: with role genuinely threaded through, a
        // caller stating the wrong role must be refused, not silently
        // admitted via the unchecked no-role path.
        let mismatched = handle(
            Host::new(&client, &wasm_path(), &config, &lambda_client::NeverInvoker),
            "Banking::Customer.Register",
            register("CUST-0010"),
            Some("Teller"),
        )
        .await
        .unwrap();
        assert!(
            !mismatched.accepted,
            "a caller stating the wrong role must be refused, not silently admitted: {:?}",
            mismatched.result
        );
        let refusals = mismatched.result["refusals"].as_array().unwrap();
        assert_eq!(refusals.len(), 1);
        let error = refusals[0]["error"].as_str().unwrap();
        assert!(
            error.contains("Branch clerk") && error.contains("Teller"),
            "the refusal should name both the declared role and the caller's mismatched one \
             (`check_role`'s own message shape): {refusals:?}"
        );

        // And the refused command was never persisted — same discipline
        // every other refusal in this file is held to.
        let steps = client.journal_steps().await;
        assert_eq!(
            steps.len(),
            1,
            "only the correctly-authorized registration should be persisted"
        );
    }

    // ADR 0081 keeps a needed fact the caller supplied, but only the host and its peers may: a
    // request's `now` would move a time-window guard.
    #[test]
    fn only_a_request_from_outside_the_host_has_its_needed_facts_replaced() {
        let ir = serde_json::json!({"name": "Lease", "aggregates": [{"name": "Slot", "commands": [
            {"name": "Take", "attributes": [{"name": "now", "type": "Integer"}],
             "needs": [{"fact": "now"}]}
        ]}]});
        let fill = |origin: Origin| {
            let mut args = serde_json::json!({"with": {"now": 42}});
            let clock = crate::needs::FixedClock(7);
            fill_arguments(origin, &ir, "Lease::Slot.Take", &mut args, &clock);
            args["with"]["now"].clone()
        };
        assert_eq!(fill(Origin::Request), serde_json::json!(7));
        assert_eq!(fill(Origin::External), serde_json::json!(42));
        assert_eq!(fill(Origin::HostInternal), serde_json::json!(42));
    }

    #[test]
    fn enforcement_reads_off_shadow_and_enforce_and_treats_anything_else_as_off() {
        assert_eq!(Enforcement::parse(None), Enforcement::Off);
        assert_eq!(Enforcement::parse(Some("")), Enforcement::Off);
        assert_eq!(Enforcement::parse(Some("nonsense")), Enforcement::Off);
        assert_eq!(Enforcement::parse(Some("Shadow")), Enforcement::Shadow);
        assert_eq!(Enforcement::parse(Some(" enforce ")), Enforcement::Enforce);
    }

    #[test]
    fn only_an_unidentified_caller_becomes_anonymous_and_only_when_roles_are_checked() {
        let nobody = Caller::default();
        assert_eq!(Enforcement::Off.effective(nobody), nobody);
        for mode in [Enforcement::Shadow, Enforcement::Enforce] {
            assert_eq!(mode.effective(nobody).role, Some(ANONYMOUS_ROLE));
            let stated = Caller {
                role: Some("Teller"),
                actor_id: None,
            };
            assert_eq!(mode.effective(stated), stated, "a stated role is kept");
            let identified = Caller {
                role: None,
                actor_id: Some("u1"),
            };
            assert_eq!(
                mode.effective(identified),
                identified,
                "an identified caller is kept"
            );
        }
    }

    // The unidentified caller is the case the host never refused: no role at all.
    #[tokio::test]
    async fn an_unidentified_caller_is_refused_when_enforced_and_let_through_when_off_or_shadowed()
    {
        let client = crate::dispatch_tests::tests::memory_store();
        let config = crate::dispatch_tests::tests::memory_config("Banking");
        let go = |mode: Enforcement, id: &'static str| {
            let client = &client;
            let config = &config;
            async move {
                dispatch_in(
                    mode,
                    Origin::External,
                    Host::new(client, &wasm_path(), config, &lambda_client::NeverInvoker),
                    "Banking::Customer.Register",
                    register(id),
                    Caller::default(),
                )
                .await
                .unwrap()
            }
        };

        let off = go(Enforcement::Off, "CUST-0021").await;
        assert!(
            off.accepted,
            "off keeps the old behaviour: {:?}",
            off.result
        );

        let enforced = go(Enforcement::Enforce, "CUST-0022").await;
        assert!(
            !enforced.accepted,
            "an unidentified caller must be refused: {:?}",
            enforced.result
        );
        assert!(refused_for_role(&enforced.result), "{:?}", enforced.result);
        let error = enforced.result["refusals"][0]["error"].as_str().unwrap();
        assert!(
            error.contains("Branch clerk") && error.contains(ANONYMOUS_ROLE),
            "{error}"
        );

        let shadowed = go(Enforcement::Shadow, "CUST-0023").await;
        assert!(
            shadowed.accepted,
            "shadow lets the command through: {:?}",
            shadowed.result
        );

        let steps = client.journal_steps().await;
        assert_eq!(
            steps.len(),
            2,
            "the enforced refusal was not persisted; off and shadow were"
        );
    }

    // Shadow may only let through what Off would: a caller that stated a wrong role is refused.
    #[tokio::test]
    async fn shadow_refuses_a_stated_wrong_role_and_still_lets_an_unidentified_caller_through() {
        let client = crate::dispatch_tests::tests::memory_store();
        let config = crate::dispatch_tests::tests::memory_config("Banking");
        let go = |mode: Enforcement, origin: Origin, caller: Caller<'static>, id: &'static str| {
            let client = &client;
            let config = &config;
            async move {
                dispatch_in(
                    mode,
                    origin,
                    Host::new(client, &wasm_path(), config, &lambda_client::NeverInvoker),
                    "Banking::Customer.Register",
                    register(id),
                    caller,
                )
                .await
                .unwrap()
            }
        };
        let wrong = Caller {
            role: Some("Auditor"),
            actor_id: None,
        };

        let shadow_wrong = go(Enforcement::Shadow, Origin::External, wrong, "CUST-0031").await;
        assert!(
            !shadow_wrong.accepted,
            "shadow must not accept a stated wrong role: {:?}",
            shadow_wrong.result
        );
        assert!(
            refused_for_role(&shadow_wrong.result),
            "{:?}",
            shadow_wrong.result
        );
        let off_wrong = go(Enforcement::Off, Origin::External, wrong, "CUST-0032").await;
        assert!(
            !off_wrong.accepted,
            "off refuses it too: {:?}",
            off_wrong.result
        );

        let nobody = go(
            Enforcement::Shadow,
            Origin::External,
            Caller::default(),
            "CUST-0033",
        )
        .await;
        assert!(
            nobody.accepted,
            "shadow lets an unidentified caller through: {:?}",
            nobody.result
        );

        let steps = client.journal_steps().await;
        assert_eq!(
            steps.len(),
            1,
            "only the unidentified caller's registration was persisted"
        );
    }

    // A host-internal dispatch names no caller and is unchecked in every mode, while an external
    // unidentified caller is refused under enforce.
    #[tokio::test]
    async fn a_host_internal_dispatch_is_unchecked_under_enforce_but_an_external_one_is_refused() {
        let client = crate::dispatch_tests::tests::memory_store();
        let config = crate::dispatch_tests::tests::memory_config("Banking");
        let go = |mode: Enforcement, origin: Origin, id: &'static str| {
            let client = &client;
            let config = &config;
            async move {
                dispatch_in(
                    mode,
                    origin,
                    Host::new(client, &wasm_path(), config, &lambda_client::NeverInvoker),
                    "Banking::Customer.Register",
                    register(id),
                    Caller::default(),
                )
                .await
                .unwrap()
            }
        };

        let external = go(Enforcement::Enforce, Origin::External, "CUST-0041").await;
        assert!(!external.accepted, "{:?}", external.result);
        for (mode, id) in [
            (Enforcement::Enforce, "CUST-0042"),
            (Enforcement::Shadow, "CUST-0043"),
            (Enforcement::Off, "CUST-0044"),
        ] {
            let internal = go(mode, Origin::HostInternal, id).await;
            assert!(internal.accepted, "{mode:?}: {:?}", internal.result);
        }
    }

    #[tokio::test]
    async fn a_mid_transaction_failure_rolls_back_any_saga_state_already_written() {
        // Deliberately doesn't provision "Transfer": its mutation fails
        // after `begin_saga` already wrote into `hecks_lambda_sagas`,
        // proving that write rolls back with the rest of the transaction.
        let client = scratch_db("rust_host_dispatch_test_9").await;
        provision_lineage(
            &*client.lock().await,
            "Banking",
            1,
            &["Customer", "Account"],
        )
        .await;
        let config = test_config("Banking", 1);

        handle(
            Host::new(&client, &wasm_path(), &config, &lambda_client::NeverInvoker),
            "Banking::Customer.Register",
            register("CUST-0012"),
            None,
        )
        .await
        .unwrap()
        .accepted
        .then_some(())
        .expect("registration should succeed");

        let open_src = serde_json::json!({
            "number": { "value": "src-rollback" }, "kind": { "name": "current" },
            "daily_limit": { "cents": 50000 }, "customer": "CUST-0012",
        });
        handle(
            Host::new(&client, &wasm_path(), &config, &lambda_client::NeverInvoker),
            "Banking::Account.Open",
            open_src,
            None,
        )
        .await
        .unwrap()
        .accepted
        .then_some(())
        .expect("source account open should succeed");
        let open_dst = serde_json::json!({
            "number": { "value": "dst-rollback" }, "kind": { "name": "current" },
            "daily_limit": { "cents": 50000 }, "customer": "CUST-0012",
        });
        handle(
            Host::new(&client, &wasm_path(), &config, &lambda_client::NeverInvoker),
            "Banking::Account.Open",
            open_dst,
            None,
        )
        .await
        .unwrap()
        .accepted
        .then_some(())
        .expect("destination account open should succeed");
        handle(Host::new(&client, &wasm_path(), &config, &lambda_client::NeverInvoker), "Banking::Account.Credit", serde_json::json!({ "number": "src-rollback", "amount": { "cents": 1000 }, "narrative": { "text": "opening balance" } }), None)
        .await.unwrap().accepted.then_some(()).expect("credit should succeed");

        // `Transfer.Request`'s own mutation is the first one this step
        // produces, and "Transfer" was never provisioned, so it fails
        // before the saga cascade runs further.
        let transfer_args = serde_json::json!({
            "reference": { "value": "tr-rollback" }, "amount": { "cents": 200 },
            "narrative": { "text": "rollback test" }, "source": "src-rollback", "destination": "dst-rollback",
        });
        let outcome = handle(
            Host::new(&client, &wasm_path(), &config, &lambda_client::NeverInvoker),
            "Banking::Transfer.Request",
            transfer_args,
            None,
        )
        .await;
        assert!(
            outcome.is_err(),
            "the unprovisioned Transfer lineage table should make this whole invocation fail"
        );

        let guard = client.lock().await;
        let saga_rows = guard
            .query(
                "SELECT process_manager, correlation FROM hecks_lambda_sagas",
                &[],
            )
            .await
            .unwrap();
        assert_eq!(
            saga_rows.len(), 0,
            "a saga write inside a transaction that ultimately fails must roll back with it, not commit independently: {saga_rows:?}"
        );
    }

    #[tokio::test]
    async fn a_pre_existing_snapshot_without_the_sagas_backfilled_latch_forces_one_full_replay() {
        let client = scratch_db("rust_host_dispatch_test_10").await;
        provision_lineage(
            &*client.lock().await,
            "Banking",
            1,
            &["Customer", "Account", "Transfer"],
        )
        .await;
        let config = test_config("Banking", 1);
        // `ReviewOnFreeze` fires on every `FreezeAccount` in this domain
        // (proven above), so `NeverInvoker` would panic here.
        let invoker = RecordingInvoker::new();

        handle(
            Host::new(&client, &wasm_path(), &config, &invoker),
            "Banking::Customer.Register",
            register("CUST-0013"),
            None,
        )
        .await
        .unwrap()
        .accepted
        .then_some(())
        .expect("registration should succeed");

        let open_src = serde_json::json!({
            "number": { "value": "src-backfill" }, "kind": { "name": "current" },
            "daily_limit": { "cents": 50000 }, "customer": "CUST-0013",
        });
        handle(
            Host::new(&client, &wasm_path(), &config, &invoker),
            "Banking::Account.Open",
            open_src,
            None,
        )
        .await
        .unwrap()
        .accepted
        .then_some(())
        .expect("source account open should succeed");
        let open_dst = serde_json::json!({
            "number": { "value": "dst-backfill" }, "kind": { "name": "current" },
            "daily_limit": { "cents": 50000 }, "customer": "CUST-0013",
        });
        handle(
            Host::new(&client, &wasm_path(), &config, &invoker),
            "Banking::Account.Open",
            open_dst,
            None,
        )
        .await
        .unwrap()
        .accepted
        .then_some(())
        .expect("destination account open should succeed");
        handle(Host::new(&client, &wasm_path(), &config, &invoker), "Banking::Account.Credit", serde_json::json!({ "number": "src-backfill", "amount": { "cents": 1000 }, "narrative": { "text": "opening balance" } }), None)
        .await.unwrap().accepted.then_some(()).expect("credit should succeed");

        // Freezing the destination first means the credit leg refuses
        // and Settlement compensates, leaving the saga stuck "reversed"
        // — exactly the mid-flight shape this test needs to recover.
        handle(
            Host::new(&client, &wasm_path(), &config, &invoker),
            "Banking::Account.FreezeAccount",
            serde_json::json!({ "number": { "value": "dst-backfill" } }),
            None,
        )
        .await
        .unwrap()
        .accepted
        .then_some(())
        .expect("freeze should succeed");
        let transfer_args = serde_json::json!({
            "reference": { "value": "tr-backfill" }, "amount": { "cents": 200 },
            "narrative": { "text": "backfill test" }, "source": "src-backfill", "destination": "dst-backfill",
        });
        handle(
            Host::new(&client, &wasm_path(), &config, &invoker),
            "Banking::Transfer.Request",
            transfer_args,
            None,
        )
        .await
        .unwrap()
        .accepted
        .then_some(())
        .expect("the Transfer.Request COMMAND succeeds; the saga's own credit leg is what refuses");

        {
            let guard = client.lock().await;
            let before = guard
                .query(
                    "SELECT process_manager, correlation, state FROM hecks_lambda_sagas",
                    &[],
                )
                .await
                .unwrap();
            assert_eq!(before.len(), 1, "the reversed Settlement instance should already be tracked before the simulated reset: {before:?}");
        }

        // Simulates a pre-saga-durability snapshot: the latch false and
        // `hecks_lambda_sagas` empty, even though a saga is genuinely
        // mid-flight.
        {
            let guard = client.lock().await;
            guard
                .execute(
                    "UPDATE hecks_lambda_snapshot SET sagas_backfilled = false",
                    &[],
                )
                .await
                .unwrap();
            guard
                .execute("DELETE FROM hecks_lambda_sagas", &[])
                .await
                .unwrap();
        }

        // One more command should trigger a full replay, whose saga
        // cascade re-running as a side effect repopulates
        // `hecks_lambda_sagas`.
        handle(
            Host::new(&client, &wasm_path(), &config, &invoker),
            "Banking::Customer.Register",
            register("CUST-0014"),
            None,
        )
        .await
        .unwrap()
        .accepted
        .then_some(())
        .expect("second registration should succeed");

        let guard = client.lock().await;
        let saga_rows = guard
            .query(
                "SELECT process_manager, correlation, state FROM hecks_lambda_sagas",
                &[],
            )
            .await
            .unwrap();
        assert_eq!(saga_rows.len(), 1, "the backfill replay should have recovered the in-flight Settlement instance: {saga_rows:?}");
        let process_manager: String = saga_rows[0].get(0);
        let correlation: String = saga_rows[0].get(1);
        let state: String = saga_rows[0].get(2);
        assert_eq!(process_manager, "Settlement");
        assert_eq!(correlation, "tr-backfill");
        assert_eq!(state, "reversed");

        let latched: bool = guard
            .query_one("SELECT sagas_backfilled FROM hecks_lambda_snapshot", &[])
            .await
            .unwrap()
            .get(0);
        assert!(latched, "after the backfill replay, the latch should be set so this doesn't repeat every invocation");
    }

    // Always fails with a hard invoke fault, the shape an unreachable
    // Lambda has — proves the exhausted-retry/dead-letter path.
    struct AlwaysFailingInvoker {
        calls: std::sync::Mutex<u32>,
    }

    impl AlwaysFailingInvoker {
        fn new() -> Self {
            Self {
                calls: std::sync::Mutex::new(0),
            }
        }
    }

    #[async_trait::async_trait]
    impl LambdaInvoker for AlwaysFailingInvoker {
        async fn invoke(
            &self,
            _function_name: &str,
            _payload: &str,
        ) -> anyhow::Result<lambda_client::InvokeOutcome> {
            *self.calls.lock().unwrap() += 1;
            anyhow::bail!("ResourceNotFoundException: function not found")
        }
    }

    #[tokio::test]
    async fn a_cross_domain_delivery_that_exhausts_every_retry_dead_letters_and_still_fails_the_invocation(
    ) {
        let client = crate::dispatch_tests::tests::memory_store();
        let config = crate::dispatch_tests::tests::memory_config("Banking");
        let invoker = AlwaysFailingInvoker::new();

        handle(
            Host::new(&client, &wasm_path(), &config, &invoker),
            "Banking::Customer.Register",
            register("CUST-0011"),
            None,
        )
        .await
        .unwrap()
        .accepted
        .then_some(())
        .expect("registration should succeed");

        let open_args = serde_json::json!({
            "number": { "value": "acct-freeze-dead-letter" },
            "kind": { "name": "current" },
            "daily_limit": { "cents": 50000 },
            "customer": "CUST-0011",
        });
        handle(
            Host::new(&client, &wasm_path(), &config, &invoker),
            "Banking::Account.Open",
            open_args,
            None,
        )
        .await
        .unwrap()
        .accepted
        .then_some(())
        .expect("account open should succeed");

        // `ReviewOnFreeze` fires here — every attempt against
        // `AlwaysFailingInvoker` fails, so `deliver_with_retry` exhausts
        // `MAX_DELIVERY_ATTEMPTS` before `handle` ever sees a result.
        let freeze_args = serde_json::json!({ "number": { "value": "acct-freeze-dead-letter" } });
        let outcome = handle(
            Host::new(&client, &wasm_path(), &config, &invoker),
            "Banking::Account.FreezeAccount",
            freeze_args,
            None,
        )
        .await;

        assert!(
            outcome.is_err(),
            "a cross-domain delivery that exhausts every retry should still fail THIS invocation \
             visibly — the local Freeze already committed regardless (checked below), this is only \
             about what the CALLER sees"
        );
        assert_eq!(
            *invoker.calls.lock().unwrap(),
            lambda_client::MAX_DELIVERY_ATTEMPTS,
            "should have retried exactly MAX_DELIVERY_ATTEMPTS times before giving up"
        );

        // The local command still committed: cross-domain delivery runs
        // strictly after commit, so a delivery failure never unwinds it.
        // The dead letter existing at all proves the match already ran.
        let dead_letters = client.dead_letter_rows().await;
        assert_eq!(
            dead_letters.len(),
            1,
            "exactly one exhausted delivery should have been dead-lettered: {dead_letters:?}"
        );
        let (policy, target_domain, target_verb, attempts) = dead_letters[0].clone();
        assert_eq!(policy, "ReviewOnFreeze");
        assert_eq!(target_domain, "Compliance");
        assert_eq!(target_verb, "Compliance::Review.Open");
        assert_eq!(attempts, lambda_client::MAX_DELIVERY_ATTEMPTS as i32);
    }

    // Pins a real drop: a second cross-domain reaction from the same
    // step must not go dark just because the first one's delivery
    // exhausted its retries. `SafeDepositBox.Surrender` emits both
    // `BoxSurrendered` (-> Compliance) and `KeyReturnRequested` (-> Notifications)
    // from one command.
    #[tokio::test]
    async fn a_failed_cross_domain_delivery_does_not_drop_a_sibling_reaction_from_the_same_step() {
        let client = crate::dispatch_tests::tests::memory_store();
        let config = crate::dispatch_tests::tests::memory_config("Banking");
        let invoker = AlwaysFailingInvoker::new();

        handle(
            Host::new(&client, &wasm_path(), &config, &invoker),
            "Banking::Customer.Register",
            register("CUST-0022"),
            None,
        )
        .await
        .unwrap()
        .accepted
        .then_some(())
        .expect("registration should succeed");

        let rent_args = serde_json::json!({
            "branch_code": { "value": "downtown" },
            "box_number": { "value": 12 },
            "size": { "value": "small" },
            "customer": "CUST-0022",
        });
        handle(
            Host::new(&client, &wasm_path(), &config, &invoker),
            "Banking::SafeDepositBox.Rent",
            rent_args,
            None,
        )
        .await
        .unwrap()
        .accepted
        .then_some(())
        .expect("rent should succeed");

        // Both ReviewOnBoxSurrender (-> Compliance) and FlagKeyReturn
        // (-> Notifications) fire here; both deliveries exhaust every
        // retry against AlwaysFailingInvoker.
        let surrender_args = serde_json::json!({ "branch_code": { "value": "downtown" }, "box_number": { "value": 12 } });
        let outcome = handle(
            Host::new(&client, &wasm_path(), &config, &invoker),
            "Banking::SafeDepositBox.Surrender",
            surrender_args,
            None,
        )
        .await;

        assert!(
            outcome.is_err(),
            "still fails the invocation visibly, same contract as a single failed delivery"
        );
        assert_eq!(
            *invoker.calls.lock().unwrap(),
            lambda_client::MAX_DELIVERY_ATTEMPTS * 2,
            "BOTH reactions should have been attempted MAX_DELIVERY_ATTEMPTS times each — \
             the fix under test is exactly this: a fresh Vec would only ever show one policy's worth"
        );

        let policies: Vec<String> = client
            .dead_letter_rows()
            .await
            .into_iter()
            .map(|row| row.0)
            .collect();
        assert_eq!(
            policies,
            vec!["FlagKeyReturn".to_string(), "ReviewOnBoxSurrender".to_string()],
            "BOTH sibling reactions must be dead-lettered, not just whichever ran first: {policies:?}"
        );
    }
    /// The wasm plugin fixture (spec/fixtures/rust_host/pluginned): its kernel and its IR, which
    /// carries the doubler plugin that answers `Ledger.Doubled` and refuses `Ledger.Tripled`.
    fn pluginned() -> (std::path::PathBuf, serde_json::Value) {
        let dist = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../dist");
        let ir = std::fs::read_to_string(dist.join("pluginned.ir.json"))
            .expect("build the pluginned fixture");
        (
            dist.join("pluginned.wasm"),
            serde_json::from_str(&ir).unwrap(),
        )
    }

    async fn ask_pluginned(
        client: &Store,
        question: &str,
        args: serde_json::Value,
    ) -> serde_json::Value {
        let (wasm, ir) = pluginned();
        let asked = serde_json::json!({ "query": question, "args": args });
        crate::query_step::answer(&asked, Some(&ir), "Pluginned", client, &wasm)
            .await
            .unwrap()
    }

    /// A query a wasm plugin answers, end to end: a command through the real kernel stores the
    /// ledger, and the query step hands the plugin that record's state, read back from Postgres.
    #[tokio::test]
    async fn a_plugin_answers_with_the_referenced_record_as_stored() {
        let client = scratch_db("rust_host_dispatch_test_plugin").await;
        provision_lineage(&*client.lock().await, "Pluginned", 1, &["Ledger"]).await;
        let (wasm, _) = pluginned();
        let config = test_config("Pluginned", 1);
        let opened = handle(
            Host::new(&client, &wasm, &config, &lambda_client::NeverInvoker),
            "Pluginned::Ledger.Open",
            serde_json::json!({ "name": { "value": "house" }, "note": { "value": "rent" } }),
            None,
        )
        .await
        .unwrap();
        assert!(
            opened.accepted,
            "opening the ledger: {}",
            opened.result["refusals"]
        );

        let answer = ask_pluginned(
            &client,
            "Pluginned::Ledger.Doubled",
            serde_json::json!({ "entry": "house", "amount": 21 }),
        )
        .await;

        assert_eq!(
            answer["queries"][0]["rows"],
            serde_json::json!([{ "amount": 42, "note": "rent" }])
        );
    }

    #[tokio::test]
    async fn a_plugin_refusal_and_a_missing_record_come_back_as_refusals() {
        let client = scratch_db("rust_host_dispatch_test_plugin_refusals").await;
        provision_lineage(&*client.lock().await, "Pluginned", 1, &["Ledger"]).await;

        let refused = ask_pluginned(
            &client,
            "Pluginned::Ledger.Tripled",
            serde_json::json!({ "amount": 1 }),
        )
        .await;
        let missing = ask_pluginned(
            &client,
            "Pluginned::Ledger.Doubled",
            serde_json::json!({ "entry": "nowhere", "amount": 1 }),
        )
        .await;

        assert_eq!(refused["refusals"][0]["kind"], "PluginRefusal");
        let refusal = refused["refusals"][0]["error"].as_str().unwrap();
        assert!(
            refusal.contains("doubler does not answer Pluginned::Ledger.Tripled"),
            "{refusal}"
        );
        assert_eq!(missing["refusals"][0]["kind"], "NotFound");
        assert_eq!(
            missing["refusals"][0]["error"],
            "entry: no Ledger \"nowhere\""
        );
    }
}

#[cfg(test)]
mod preview_tests {
    use crate::dispatch_tests::tests::{memory_config, memory_store, register, wasm_path};
    use crate::host::Host;
    use crate::journal;
    use crate::lambda_client;
    use crate::store::{Accepted, DeadLetter, LineageWrite, Store, StoreExt, StoreFixtures};
    use crate::wasm_runner;
    use rust_host_core::dispatch::*;
    use std::path::Path;

    // The client envelope a preview of `verb` answers for `invocation`.
    async fn preview_of(
        client: &Store,
        verb: &str,
        invocation: serde_json::Value,
    ) -> serde_json::Value {
        let config = memory_config("Banking");
        let wasm = wasm_path();
        let host = Host::new(client, &wasm, &config, &lambda_client::NeverInvoker);
        let outcome = preview_as(host, verb, invocation, Caller::default())
            .await
            .unwrap();
        crate::validation::answer(&outcome.result)
    }

    async fn preview(client: &Store, facts: serde_json::Value) -> serde_json::Value {
        preview_of(
            client,
            "Banking::Customer.Register",
            facts_invocation(facts).unwrap(),
        )
        .await
    }

    async fn register_for_real(client: &Store, id: &str) -> Outcome {
        let config = memory_config("Banking");
        let wasm = wasm_path();
        let host = Host::new(client, &wasm, &config, &lambda_client::NeverInvoker);
        handle_facts(host, "Banking::Customer.Register", register(id), None)
            .await
            .unwrap()
    }

    #[tokio::test]
    async fn a_preview_of_an_acceptable_command_answers_ok_and_keeps_nothing() {
        let client = memory_store();
        assert_eq!(
            preview(&client, register("CUST-P1")).await,
            serde_json::json!({ "ok": true, "refusals": [] })
        );
        assert!(
            register_for_real(&client, "CUST-P1").await.accepted,
            "the preview left a record behind, so the real registration was refused"
        );
    }

    #[tokio::test]
    async fn a_preview_of_a_refused_command_answers_why_with_its_kind_and_stage() {
        let client = memory_store();
        register_for_real(&client, "CUST-P2").await;
        let answer = preview(&client, register("CUST-P2")).await;
        assert_eq!(answer["ok"], false);
        let refusal = &answer["refusals"][0];
        assert_eq!(refusal["refusal"], "AlreadyExists");
        assert_eq!(
            (refusal["kind"].as_str(), refusal["stage"].as_str()),
            (Some("refused"), Some("state"))
        );
    }

    #[tokio::test]
    async fn a_preview_names_an_unknown_argument_in_the_arguments_stage() {
        let client = memory_store();
        let mut facts = register("CUST-P3");
        facts["bogus"] = serde_json::json!(1);
        let answer = preview(&client, facts).await;
        let refusal = &answer["refusals"][0];
        assert_eq!(refusal["refusal"], "UnknownArgument");
        assert_eq!(refusal["stage"], "arguments");
    }

    #[tokio::test]
    async fn a_preview_against_an_existing_record_is_routed_to_it() {
        let client = memory_store();
        register_for_real(&client, "CUST-P4").await;
        let close = routed_invocation(serde_json::json!("CUST-P4"), serde_json::json!({})).unwrap();
        assert_eq!(
            preview_of(&client, "Banking::Customer.Close", close).await,
            serde_json::json!({ "ok": true, "refusals": [] })
        );
    }

    #[tokio::test]
    async fn a_preview_against_a_record_that_does_not_exist_is_kind_not_found() {
        let client = memory_store();
        let close = routed_invocation(serde_json::json!("NOBODY"), serde_json::json!({})).unwrap();
        let answer = preview_of(&client, "Banking::Customer.Close", close).await;
        assert_eq!(answer["ok"], false);
        assert_eq!(answer["refusals"][0]["kind"], "not_found");
    }

    // The body protocol: `"dry_run": true` beside a command, answered as the client envelope even
    // when the request also asks for `bare`.
    #[tokio::test]
    async fn the_body_protocol_answers_a_dry_run_as_the_client_envelope() {
        let client = memory_store();
        let config = memory_config("Banking");
        let wasm = wasm_path();
        let host = Host::new(&client, &wasm, &config, &lambda_client::NeverInvoker);
        let body = serde_json::json!({
            "verb": "Banking::Customer.Register", "with": register("CUST-P5"),
            "dry_run": true, "bare": true,
        });
        let answer = crate::server::dispatch_body(body, host).await.unwrap();
        assert_eq!(answer, serde_json::json!({ "ok": true, "refusals": [] }));
    }
}
