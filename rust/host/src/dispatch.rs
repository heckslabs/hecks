// TIES THE JOURNAL AND THE SANDBOX TOGETHER — this is the one place
// that knows both halves exist; wasm_runner and journal each stay
// ignorant of the other. `handle` is the whole rehydrate-replay
// contract in one function: read history, replay history + the new
// step, persist the new step iff the module itself accepted it.

use crate::journal;
use crate::journal::LineageConfig;
use crate::wasm_runner;
use std::path::Path;
use tokio::sync::Mutex;
use tokio_postgres::Client;

pub struct Outcome {
    pub result: serde_json::Value,
    pub accepted: bool,
}

// A Mutex, not a bare Arc<Client> — `handle` needs `Client::transaction`,
// which takes `&mut Client`. Locking here also means that if this
// process is ever invoked concurrently in-process (lambda_runtime's
// default loop is one-event-at-a-time, but nothing in this crate
// depends on that staying true), two calls can't interleave statements
// on the one connection this crate holds.
//
// `config` names which Ruby-shaped lineage journal/era this call writes
// its mutations into (journal.rs's own header) — required, not
// optional: `main.rs` already refused to boot if the configured
// domain/era isn't provisioned (`journal::era_exists`), so by the time
// `handle` runs that schema is guaranteed to exist.
pub async fn handle(
    client: &Mutex<Client>,
    wasm_path: &Path,
    verb: &str,
    args: serde_json::Value,
    config: &LineageConfig,
) -> anyhow::Result<Outcome> {
    let mut guard = client.lock().await;
    let txn = guard.transaction().await?;

    // SERIALIZES THE WHOLE READ-THEN-APPEND SEQUENCE, not just the
    // final INSERT — mirrors postgres.rb's own `pg_advisory_xact_lock`
    // around its ordinal-assigning append (postgres.rb:118-124: "HELD
    // FOR THE WHOLE TRANSACTION, not just around the INSERT"). Without
    // this, two concurrent Lambda invocations (separate execution
    // environments, separate connections — exactly what advisory locks
    // are for) could both rehydrate against the same prior steps, both
    // pass a uniqueness check the domain thinks it's enforcing, and
    // both append: the replay-determinism argument in journal.rs's own
    // header only holds if invocations serialize.
    //
    // DOMAIN-SCOPED KEY, same as postgres.rb's own `hecks_ordinal:` —
    // this was a single fixed key until the storehouse (multiple
    // domains sharing one Postgres instance, isolated by schema): a
    // fixed key would incorrectly serialize every domain's invocations
    // against every OTHER domain's, not just against itself. Each
    // domain's own `search_path` already keeps `hecks_lambda_journal`
    // itself schema-isolated (main.rs sets it at boot); this makes the
    // LOCK isolated the same way, so domains sharing the instance don't
    // queue behind each other.
    txn.execute(
        "SELECT pg_advisory_xact_lock(hashtext('hecks_lambda_journal.' || $1::text))",
        &[&config.domain],
    )
    .await?;

    // SEED, NOT FULL REPLAY — read the last known-good snapshot (the
    // kernel's own prior "instances" output) and only the journal rows
    // AFTER it, instead of the whole command history every single time.
    // `None` covers two real cases identically: a brand-new domain (no
    // snapshot, no history — Store::new()/empty seed, exactly today's
    // behavior) and a domain with journal history from BEFORE this
    // snapshot cache existed (no snapshot row yet, but real prior
    // steps) — that one self-heals by falling back to a full replay
    // ONCE, same as always, which then leaves behind a snapshot for
    // every invocation after it. See journal.rs's own header.
    let snapshot = journal::load_snapshot(&txn).await?;
    let mut steps = match &snapshot {
        Some(s) => journal::load_steps_after(&txn, s.ordinal).await?,
        None => journal::load_steps(&txn).await?,
    };
    steps.push(serde_json::json!({ "verb": verb, "args": args.clone() }));
    let seed = snapshot.as_ref().map(|s| s.seed.clone()).unwrap_or_else(|| serde_json::json!({}));

    let input = serde_json::json!({ "seed": seed, "steps": steps }).to_string();
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
        let ordinal = journal::append(&txn, verb, &args).await?;

        // Refreshes the snapshot to the NEW world this command just
        // produced — the kernel's own "instances" output already IS
        // the exact seed shape (Store::instances/Store::from_seed are
        // mechanical inverses), so nothing here re-derives or filters
        // it. Every accepted command leaves the snapshot current, which
        // is what makes `load_steps_after` above normally find nothing
        // to replay at all.
        let new_seed = result.get("instances").cloned().unwrap_or_else(|| serde_json::json!({}));
        journal::save_snapshot(&txn, ordinal, &new_seed).await?;

        // The kernel's new per-step "mutations" field (adf38fd) — one
        // entry per step in `steps` above, so the LAST entry is exactly
        // this call's own new step (everything before it is history
        // already recorded on a prior, successful invocation). Written
        // into Ruby's own per-aggregate journal/head-snapshot schema,
        // same transaction, same advisory lock already held — see
        // journal.rs's own header for why this doesn't replace the
        // hecks_lambda_journal append just above, only supplements it.
        let step_mutations = result
            .get("mutations")
            .and_then(|m| m.as_array())
            .and_then(|steps| steps.last())
            .and_then(|last| last.as_array())
            .cloned()
            .unwrap_or_default();

        for mutation in &step_mutations {
            let aggregate = mutation
                .get("aggregate")
                .and_then(|v| v.as_str())
                .ok_or_else(|| anyhow::anyhow!("mutation record missing \"aggregate\": {mutation}"))?;
            let id = mutation
                .get("id")
                .and_then(|v| v.as_str())
                .ok_or_else(|| anyhow::anyhow!("mutation record missing \"id\": {mutation}"))?;
            let operation = mutation
                .get("operation")
                .and_then(|v| v.as_str())
                .ok_or_else(|| anyhow::anyhow!("mutation record missing \"operation\": {mutation}"))?;
            let state = mutation
                .get("state")
                .ok_or_else(|| anyhow::anyhow!("mutation record missing \"state\": {mutation}"))?;

            journal::append_lineage_mutation(
                &txn,
                config,
                &journal::Mutation { aggregate, id, operation, state },
            )
            .await?;
        }
    }

    // Commits (and releases the advisory lock) whether or not anything
    // was appended — a refused command still needs the lock released
    // for the next invocation to proceed.
    txn.commit().await?;

    Ok(Outcome { result, accepted })
}

// READ-ONLY: the SAME seed-not-replay path `handle` uses (journal.rs's
// own header), minus the new step and minus any write. No advisory
// lock needed — nothing here writes, so a plain snapshot read is
// enough (Postgres's own read-committed guarantee is already stronger
// than anything a lock would add for a read). Every step replayed here
// already succeeded once (journal.rs's own determinism argument), so
// `refusals` in the returned JSON should always come back empty — this
// returns the whole result verbatim rather than unwrapping just
// `instances`, so a caller can tell the two apart instead of that
// being silently assumed.
pub async fn read(client: &Mutex<Client>, wasm_path: &Path) -> anyhow::Result<serde_json::Value> {
    let guard = client.lock().await;
    let snapshot = journal::load_snapshot(&*guard).await?;

    if let Some(s) = &snapshot {
        let steps_since = journal::load_steps_after(&*guard, s.ordinal).await?;
        drop(guard);

        if steps_since.is_empty() {
            // THE FAST PATH — no wasm invocation at all. The snapshot's
            // own `seed` IS this domain's current "instances" output
            // already (`save_snapshot` writes it verbatim from a real
            // dispatch's own result), so there's nothing left to
            // compute. Empty events/refusals is correct here too — a
            // read reports CURRENT STATE, never an event/refusal
            // history (this function's own pre-existing contract).
            return Ok(serde_json::json!({ "instances": s.seed, "events": [], "refusals": [] }));
        }

        // Self-healing tail replay — nothing in this crate today
        // leaves steps unaccounted for after the last snapshot, but if
        // it ever did, seeding from the snapshot and replaying just the
        // gap is still correct and still cheap, same reasoning as
        // `handle`'s own fallback.
        let input = serde_json::json!({ "seed": &s.seed, "steps": steps_since }).to_string();
        let owned_wasm_path = wasm_path.to_path_buf();
        let output =
            tokio::task::spawn_blocking(move || wasm_runner::run(&owned_wasm_path, &input)).await??;
        return Ok(serde_json::from_str(&output)?);
    }

    // No snapshot at all — a brand-new domain (empty history, correctly
    // reports nothing) or one with journal history from BEFORE this
    // snapshot cache existed (a real, one-time full replay to catch up
    // — see journal.rs's own header on why this is self-healing, not
    // an error case).
    let steps = journal::load_steps(&*guard).await?;
    drop(guard);
    let input = serde_json::json!({ "steps": steps }).to_string();
    let owned_wasm_path = wasm_path.to_path_buf();
    let output =
        tokio::task::spawn_blocking(move || wasm_runner::run(&owned_wasm_path, &input)).await??;
    Ok(serde_json::from_str(&output)?)
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
    async fn scratch_db(name: &str) -> Mutex<Client> {
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
        Mutex::new(client)
    }

    // NOT Ruby's real provisioning (Lineage::Provisioning) -- no
    // partitioning, no RLS, no full hecks_eras column set. Just enough
    // structure for `journal::era_exists` and `append_lineage_mutation`'s
    // own INSERT/upsert statements to succeed, so these tests exercise
    // THIS crate's write logic without reproducing Ruby's full DDL --
    // era_exists's own query only ever reads domain/ordinal, so a
    // minimal hecks_eras row satisfies the SAME boot-gate check main.rs
    // runs for real.
    async fn provision_lineage(client: &Client, domain: &str, era: i32, aggregate_storage_names: &[&str]) {
        // `int`, matching Ruby's real DDL (era_store.rb's `ordinal int
        // NOT NULL`, provisioning.rb's `era int NOT NULL`) exactly —
        // LineageConfig::era is i32 for the same reason: tokio_postgres
        // requires the Rust and Postgres types to match, not just be
        // numerically compatible, and this fixture should mirror the
        // real schema, not a convenient stand-in for it.
        client
            .batch_execute("CREATE TABLE IF NOT EXISTS hecks_eras (domain text, ordinal int, held_text text)")
            .await
            .unwrap();
        client
            .execute(
                "INSERT INTO hecks_eras (domain, ordinal, held_text) VALUES ($1, $2, 'test')",
                &[&domain, &era],
            )
            .await
            .unwrap();

        let journal_table = format!("hecks_journal_{}", journal::snake(domain));
        client
            .batch_execute(&format!(
                "CREATE TABLE IF NOT EXISTS \"{journal_table}\" (
                    ordinal      bigserial PRIMARY KEY,
                    era          int NOT NULL,
                    aggregate    text NOT NULL,
                    aggregate_id text NOT NULL,
                    operation    text NOT NULL,
                    state        jsonb
                )"
            ))
            .await
            .unwrap();

        for name in aggregate_storage_names {
            let snapshot_table = format!("{}_head_snapshot_{era}", journal::snake(name));
            client
                .batch_execute(&format!(
                    "CREATE TABLE IF NOT EXISTS \"{snapshot_table}\" (id text PRIMARY KEY, ordinal bigint NOT NULL, state jsonb NOT NULL)"
                ))
                .await
                .unwrap();
        }
    }

    fn test_config(domain: &str, era: i32) -> LineageConfig {
        LineageConfig { domain: domain.to_string(), era }
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
        provision_lineage(&*client.lock().await, "Banking", 1, &["Customer"]).await;

        let outcome = handle(
            &client,
            &wasm_path(),
            "Banking::Customer.Register",
            register("CUST-0001"),
            &test_config("Banking", 1),
        )
        .await
        .unwrap();

        assert!(outcome.accepted);
        assert_eq!(outcome.result["refusals"].as_array().unwrap().len(), 0);
        let guard = client.lock().await;
        let steps = journal::load_steps(&*guard).await.unwrap();
        assert_eq!(steps.len(), 1);

        // THE LINEAGE WRITE ITSELF — a row landed in Ruby's own journal
        // shape (era-tagged, storage-name-keyed), not just the flat
        // command log above.
        let journal_rows = guard
            .query("SELECT era, aggregate, aggregate_id, operation FROM hecks_journal_banking", &[])
            .await
            .unwrap();
        assert_eq!(journal_rows.len(), 1);
        let row = &journal_rows[0];
        let era: i32 = row.get(0);
        let aggregate: String = row.get(1);
        let aggregate_id: String = row.get(2);
        let operation: String = row.get(3);
        assert_eq!((era, aggregate.as_str(), aggregate_id.as_str(), operation.as_str()), (1, "customer", "CUST-0001", "save"));

        let snapshot_rows = guard
            .query("SELECT id FROM customer_head_snapshot_1", &[])
            .await
            .unwrap();
        assert_eq!(snapshot_rows.len(), 1, "the head-snapshot table should carry exactly the one live record");
        let id: String = snapshot_rows[0].get(0);
        assert_eq!(id, "CUST-0001");
    }

    #[tokio::test]
    async fn rehydrates_prior_history_before_evaluating_the_new_command() {
        let client = scratch_db("rust_host_dispatch_test_2").await;
        provision_lineage(&*client.lock().await, "Banking", 1, &["Customer"]).await;
        let config = test_config("Banking", 1);

        let first = handle(
            &client,
            &wasm_path(),
            "Banking::Customer.Register",
            register("CUST-0001"),
            &config,
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
            &config,
        )
        .await
        .unwrap();

        assert!(
            !second.accepted,
            "duplicate registration should be refused, proving prior state was rehydrated: {:?}",
            second.result
        );
        let steps = journal::load_steps(&*client.lock().await).await.unwrap();
        assert_eq!(
            steps.len(),
            1,
            "the refused duplicate must not be persisted"
        );
    }

    #[tokio::test]
    async fn the_snapshot_stays_current_so_nothing_replays_full_history() {
        // THE DIRECT PROOF of what `rehydrates_prior_history...` above
        // only proves indirectly (via the duplicate-refusal side
        // effect): after every accepted command, `load_steps_after` the
        // snapshot's own ordinal should find NOTHING — the snapshot
        // genuinely stays current, so `handle` never needs a full
        // replay after the very first command ever accepted.
        let client = scratch_db("rust_host_dispatch_test_5").await;
        provision_lineage(&*client.lock().await, "Banking", 1, &["Customer"]).await;
        let config = test_config("Banking", 1);

        for reference in ["CUST-0004", "CUST-0005", "CUST-0006"] {
            let outcome = handle(&client, &wasm_path(), "Banking::Customer.Register", register(reference), &config)
                .await
                .unwrap();
            assert!(outcome.accepted, "registering {reference} should succeed: {:?}", outcome.result);

            let guard = client.lock().await;
            let snapshot = journal::load_snapshot(&*guard)
                .await
                .unwrap()
                .expect("a snapshot should exist after the first accepted command");
            let tail = journal::load_steps_after(&*guard, snapshot.ordinal).await.unwrap();
            assert!(tail.is_empty(), "the snapshot should already reflect every accepted command, leaving nothing to replay");

            // AND THE SEED ITSELF IS RIGHT, not just empty-by-coincidence
            // — it should carry every customer registered so far, not
            // just the one just dispatched.
            let seeded = snapshot.seed.as_object().unwrap();
            assert!(
                seeded.keys().any(|k| k.contains(reference)),
                "the snapshot should carry the record just dispatched: {seeded:?}"
            );
        }

        let final_snapshot = journal::load_snapshot(&*client.lock().await).await.unwrap().unwrap();
        let final_seed = final_snapshot.seed.as_object().unwrap();
        assert_eq!(final_seed.len(), 3, "the snapshot should accumulate all three registrations, not just the latest: {final_seed:?}");
    }

    #[tokio::test]
    async fn serializes_concurrent_invocations_against_the_same_journal() {
        // THE RACE THE ADVISORY LOCK CLOSES: without it, two concurrent
        // registrations of the SAME reference could both rehydrate
        // against zero prior steps, both see no conflict, and both get
        // appended — silently violating the uniqueness the domain
        // itself enforces. With the lock serializing the whole
        // read-then-append sequence, exactly one must be accepted.
        let client = scratch_db("rust_host_dispatch_test_3").await;
        provision_lineage(&*client.lock().await, "Banking", 1, &["Customer"]).await;
        let config = test_config("Banking", 1);
        let wasm_path = wasm_path();

        let (first, second) = tokio::join!(
            handle(&client, &wasm_path, "Banking::Customer.Register", register("CUST-0002"), &config),
            handle(&client, &wasm_path, "Banking::Customer.Register", register("CUST-0002"), &config),
        );
        let (first, second) = (first.unwrap(), second.unwrap());

        assert_ne!(
            first.accepted, second.accepted,
            "exactly one of two concurrent duplicate registrations should be accepted: {:?} / {:?}",
            first.result, second.result
        );
        let steps = journal::load_steps(&*client.lock().await).await.unwrap();
        assert_eq!(steps.len(), 1, "only the accepted registration should be persisted");
    }

    #[tokio::test]
    async fn read_reflects_prior_dispatches_without_persisting_anything_new() {
        let client = scratch_db("rust_host_dispatch_test_4").await;
        provision_lineage(&*client.lock().await, "Banking", 1, &["Customer"]).await;

        handle(
            &client,
            &wasm_path(),
            "Banking::Customer.Register",
            register("CUST-0003"),
            &test_config("Banking", 1),
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

        // THE SHARP PROOF a read never appends: the journal is exactly
        // as long after the read as it was before it.
        let steps = journal::load_steps(&*client.lock().await).await.unwrap();
        assert_eq!(steps.len(), 1, "a read must never persist a journal row");
    }
}
