//! What any journal backend must do for the host to be correct, stated against a small harness
//! trait and run against every backend that implements it.
//!
//! The cases pin the commit clause of the semantics standard (C7.2, C8.4): a refused or failed
//! command leaves nothing behind, an accepted one lands in one atomic scope, and the domain lock
//! serializes writers while reads take none. Each case drives the real dispatch path and the real
//! compiled kernel, and asserts only what a caller or a second reader could observe.
//!
//! A backend joins by implementing [`Backend`] and listing the cases in `conformance_suite!`.
//! Everything a case needs from outside the dispatch path (reading the stores, planting a damaged
//! snapshot, injecting a failed write, holding the domain lock from a competing writer) is a
//! harness method, so the cases never name a table.

use crate::dispatch::{self, Caller, Outcome};
use crate::dispatch_tests::tests::{
    provision_lineage, register, scratch_db, test_config, wasm_path, RecordingInvoker,
};
use crate::host::Host;
use crate::store::journal_sql::{self as journal, LineageConfig};
use crate::store::{Accepted, MemoryFault, MemoryStore, Store};
#[allow(unused_imports)]
use crate::store::{StoreExt, StoreFixtures};
use serde_json::{json, Value};
use std::time::Duration;
use tokio_postgres::{Client, NoTls};

const DOMAIN: &str = "Banking";
const REGISTER: &str = "Banking::Customer.Register";

#[derive(Debug, Clone, PartialEq)]
struct JournalRow {
    ordinal: i64,
    verb: String,
    args: Value,
}

#[derive(Debug, Clone, PartialEq)]
struct SnapshotRow {
    ordinal: i64,
    seed: Value,
    sagas_backfilled: bool,
}

#[derive(Debug, Clone, PartialEq)]
struct SagaRow {
    process_manager: String,
    correlation: String,
    state: String,
}

/// Everything a backend holds for the domain, as a second reader would see it.
#[derive(Debug, Clone, PartialEq)]
struct Observed {
    journal: Vec<JournalRow>,
    snapshot: Option<SnapshotRow>,
    sagas: Vec<SagaRow>,
    /// Rows mirrored into the lineage journal; `None` on a backend without lineage.
    lineage_rows: Option<i64>,
}

/// A write that a backend is made to refuse partway through a commit.
#[derive(Clone, Copy)]
enum Fault {
    /// The snapshot write, which follows the journal append in the same scope.
    SnapshotWrite,
    /// The lineage mutation write, which follows the saga writes in the same scope.
    LineageWrite,
}

/// One backend holding the Banking domain's journal, provisioned empty.
#[async_trait::async_trait]
trait Backend: Sized + Sync {
    /// What a competing writer holds while it owns the domain lock.
    type Held: Send;

    /// An empty store named `name`, unique to the case.
    async fn fresh(name: &str) -> Self;
    /// A second handle on the same data with its own connection, as a second process would have.
    async fn sibling(&self) -> Self;
    async fn dispatch_as(
        &self,
        verb: &str,
        args: Value,
        caller: Caller<'_>,
    ) -> anyhow::Result<Outcome>;
    async fn read(&self) -> anyhow::Result<Value>;
    async fn observe(&self) -> Observed;
    /// The store itself, for cases that drive a unit of work without the kernel.
    fn store(&self) -> &Store;
    /// Appends a journal row the snapshot does not cover, leaving a gap after the snapshot.
    async fn append_unsnapshotted(&self, verb: &str, args: &Value);
    /// Rewrites the snapshot into a shape the kernel refuses to load.
    async fn damage_snapshot(&self);
    /// Resets the store to what a snapshot written before saga durability looks like.
    async fn forget_saga_backfill(&self);
    async fn inject(&self, fault: Fault);
    async fn clear_faults(&self);
    /// Holds the next era of the Banking domain under `label` and answers its ordinal.
    async fn hold_era(&self, label: &str) -> i32;
    async fn hold_domain_lock(&self) -> Self::Held;
    async fn release_domain_lock(&self, held: Self::Held);
}

async fn dispatch<B: Backend>(backend: &B, verb: &str, args: Value) -> Outcome {
    backend
        .dispatch_as(verb, args, Caller::default())
        .await
        .unwrap_or_else(|e| panic!("{verb} should not fail: {e:#}"))
}

fn account_open(tag: &str, which: &str) -> Value {
    json!({
        "number": { "value": format!("{which}-{tag}") }, "kind": { "name": "current" },
        "daily_limit": { "cents": 50000 }, "customer": format!("CUST-{tag}"),
    })
}

/// A customer with a funded source account and an empty destination account.
async fn open_accounts<B: Backend>(backend: &B, tag: &str) {
    dispatch(backend, REGISTER, register(&format!("CUST-{tag}"))).await;
    dispatch(backend, "Banking::Account.Open", account_open(tag, "src")).await;
    dispatch(backend, "Banking::Account.Open", account_open(tag, "dst")).await;
    let credit = json!({
        "number": format!("src-{tag}"), "amount": { "cents": 1000 },
        "narrative": { "text": "opening balance" },
    });
    dispatch(backend, "Banking::Account.Credit", credit).await;
}

/// Freezing the destination makes the credit leg refuse, which leaves the transfer's saga
/// instance stored as `reversed`.
async fn freeze_destination<B: Backend>(backend: &B, tag: &str) {
    let args = json!({ "number": { "value": format!("dst-{tag}") } });
    dispatch(backend, "Banking::Account.FreezeAccount", args).await;
}

async fn request_transfer<B: Backend>(backend: &B, tag: &str) -> anyhow::Result<Outcome> {
    let args = json!({
        "reference": { "value": format!("tr-{tag}") }, "amount": { "cents": 200 },
        "narrative": { "text": "conformance" },
        "source": format!("src-{tag}"), "destination": format!("dst-{tag}"),
    });
    backend
        .dispatch_as("Banking::Transfer.Request", args, Caller::default())
        .await
}

/// The kernel's `instances` for `rows` replayed in full from an empty seed.
async fn replay_from_empty(rows: &[JournalRow]) -> Value {
    let steps: Vec<Value> = rows
        .iter()
        .map(|r| json!({ "verb": r.verb, "args": r.args }))
        .collect();
    let input = json!({ "steps": steps }).to_string();
    let output = tokio::task::spawn_blocking(move || crate::wasm_runner::run(&wasm_path(), &input))
        .await
        .expect("replay task")
        .expect("kernel run");
    let answer: Value = serde_json::from_str(&output).expect("kernel output is JSON");
    assert!(
        answer.get("error").is_none(),
        "full replay failed: {answer}"
    );
    answer["instances"].clone()
}

fn settlement(tag: &str, state: &str) -> SagaRow {
    SagaRow {
        process_manager: "Settlement".to_string(),
        correlation: format!("tr-{tag}"),
        state: state.to_string(),
    }
}

#[cfg(test)]
mod cases {
    use super::*;
    #[allow(unused_imports)]
    use crate::store::StoreFixtures;

    pub(super) async fn an_accepted_command_appends_one_journal_row<B: Backend>(db: &str) {
        let backend = B::fresh(db).await;
        for (done, reference) in ["CUST-0001", "CUST-0002", "CUST-0003"].iter().enumerate() {
            let outcome = dispatch(&backend, REGISTER, register(reference)).await;
            assert!(outcome.accepted, "{:?}", outcome.result);

            let seen = backend.observe().await;
            assert_eq!(
                seen.journal.len(),
                done + 1,
                "exactly one row per accepted command"
            );
            let snapshot = seen
                .snapshot
                .clone()
                .expect("an accepted command leaves a snapshot");
            let newest = seen.journal.last().map(|row| row.ordinal);
            assert_eq!(
                Some(snapshot.ordinal),
                newest,
                "the snapshot is paired with the newest row"
            );
            let mirrored = i64::try_from(done + 1).unwrap();
            assert!(
                seen.lineage_rows.is_none_or(|rows| rows == mirrored),
                "{seen:?}"
            );
        }
    }

    pub(super) async fn a_snapshot_and_a_gap_replay_to_the_state_of_a_full_replay<B: Backend>(
        db: &str,
    ) {
        let backend = B::fresh(db).await;
        open_accounts(&backend, "0004").await;

        let seen = backend.observe().await;
        let seed = seen.snapshot.as_ref().expect("snapshot").seed.clone();
        assert_eq!(
            seed,
            replay_from_empty(&seen.journal).await,
            "snapshot == empty seed + all steps"
        );

        backend
            .append_unsnapshotted(REGISTER, &register("CUST-0099"))
            .await;
        let seen = backend.observe().await;
        let full = replay_from_empty(&seen.journal).await;
        let read = backend.read().await.unwrap();
        assert_eq!(
            read["instances"], full,
            "snapshot + gap == empty seed + all steps"
        );

        dispatch(&backend, REGISTER, register("CUST-0098")).await;
        let seen = backend.observe().await;
        let seed = seen.snapshot.expect("snapshot").seed;
        assert_eq!(
            seed,
            replay_from_empty(&seen.journal).await,
            "the next snapshot absorbs the gap"
        );
    }

    pub(super) async fn the_journal_keeps_arguments_as_recorded_and_never_restamps<B: Backend>(
        db: &str,
    ) {
        let backend = B::fresh(db).await;
        let caller = Caller {
            role: Some("Branch clerk"),
            actor_id: None,
        };
        let first = backend
            .dispatch_as(REGISTER, register("CUST-0005"), caller)
            .await
            .unwrap();
        assert!(first.accepted, "{:?}", first.result);

        let recorded = backend.observe().await.journal;
        assert_eq!(recorded[0].verb, REGISTER);
        assert_eq!(
            recorded[0].args,
            register("CUST-0005"),
            "the caller's stamps are not argument data"
        );

        dispatch(&backend, REGISTER, register("CUST-0006")).await;
        let later = backend.observe().await.journal;
        assert_eq!(
            later[..1],
            recorded[..],
            "a later command leaves an earlier row byte-identical"
        );
    }

    pub(super) async fn a_refused_command_changes_nothing<B: Backend>(db: &str) {
        let backend = B::fresh(db).await;
        open_accounts(&backend, "0007").await;
        freeze_destination(&backend, "0007").await;
        request_transfer(&backend, "0007").await.unwrap();
        let before = backend.observe().await;

        let duplicate = dispatch(&backend, REGISTER, register("CUST-0007")).await;

        assert!(!duplicate.accepted, "{:?}", duplicate.result);
        assert_eq!(
            backend.observe().await,
            before,
            "journal, snapshot, sagas and lineage"
        );
    }

    pub(super) async fn a_kernel_failure_is_an_error_and_changes_nothing<B: Backend>(db: &str) {
        let backend = B::fresh(db).await;
        open_accounts(&backend, "0008").await;
        freeze_destination(&backend, "0008").await;
        request_transfer(&backend, "0008").await.unwrap();
        backend.damage_snapshot().await;
        let before = backend.observe().await;

        let failure = backend
            .dispatch_as(REGISTER, register("CUST-0090"), Caller::default())
            .await;

        let message = format!("{:#}", failure.err().expect("a kernel failure is an error"));
        assert!(message.contains("invalid seed"), "{message}");
        assert_eq!(
            backend.observe().await,
            before,
            "journal, snapshot, sagas and lineage"
        );
    }

    pub(super) async fn a_snapshot_write_that_fails_leaves_the_append_invisible<B: Backend>(
        db: &str,
    ) {
        let backend = B::fresh(db).await;
        dispatch(&backend, REGISTER, register("CUST-0010")).await;
        let before = backend.observe().await;

        backend.inject(Fault::SnapshotWrite).await;
        let failure = backend
            .dispatch_as(REGISTER, register("CUST-0011"), Caller::default())
            .await;

        assert!(failure.is_err(), "the failed write fails the command");
        assert_eq!(
            backend.observe().await,
            before,
            "neither the journal row nor a snapshot is visible"
        );

        backend.clear_faults().await;
        let retried = dispatch(&backend, REGISTER, register("CUST-0011")).await;
        assert!(
            retried.accepted,
            "the store is usable again: {:?}",
            retried.result
        );
        assert_eq!(backend.observe().await.journal.len(), 2);
    }

    pub(super) async fn a_saga_is_stored_with_the_command_that_produced_it<B: Backend>(db: &str) {
        let backend = B::fresh(db).await;
        open_accounts(&backend, "0012").await;
        freeze_destination(&backend, "0012").await;
        let before = backend.observe().await;
        assert!(before.sagas.is_empty());

        let outcome = request_transfer(&backend, "0012").await.unwrap();

        assert!(outcome.accepted, "{:?}", outcome.result);
        let seen = backend.observe().await;
        assert_eq!(seen.sagas, vec![settlement("0012", "reversed")]);
        assert_eq!(
            seen.journal.len(),
            before.journal.len() + 1,
            "in the same commit as its row"
        );
    }

    pub(super) async fn a_saga_write_rolls_back_with_a_command_that_fails<B: Backend>(db: &str) {
        let backend = B::fresh(db).await;
        open_accounts(&backend, "0013").await;
        freeze_destination(&backend, "0013").await;
        let before = backend.observe().await;

        backend.inject(Fault::LineageWrite).await;
        let failure = request_transfer(&backend, "0013").await;

        assert!(
            failure.is_err(),
            "the lineage write is refused after the saga was written"
        );
        assert_eq!(
            backend.observe().await,
            before,
            "the saga row did not commit alone"
        );

        backend.clear_faults().await;
        assert!(request_transfer(&backend, "0013").await.unwrap().accepted);
        assert_eq!(
            backend.observe().await.sagas,
            vec![settlement("0013", "reversed")]
        );
    }

    pub(super) async fn a_missing_backfill_latch_forces_one_full_replay<B: Backend>(db: &str) {
        let backend = B::fresh(db).await;
        open_accounts(&backend, "0014").await;
        freeze_destination(&backend, "0014").await;
        request_transfer(&backend, "0014").await.unwrap();
        backend.forget_saga_backfill().await;
        let reset = backend.observe().await;
        assert!(reset.sagas.is_empty());
        assert!(reset.snapshot.is_some_and(|s| !s.sagas_backfilled));

        dispatch(&backend, REGISTER, register("CUST-0015")).await;

        let seen = backend.observe().await;
        assert_eq!(
            seen.sagas,
            vec![settlement("0014", "reversed")],
            "re-derived by the replay"
        );
        assert!(
            seen.snapshot.is_some_and(|s| s.sagas_backfilled),
            "and the latch is set"
        );
        let again = backend.observe().await;
        dispatch(&backend, REGISTER, register("CUST-0016")).await;
        assert_eq!(
            backend.observe().await.sagas,
            again.sagas,
            "once, not on every command"
        );
    }

    pub(super) async fn a_read_takes_no_lock_and_never_writes<B: Backend>(db: &str) {
        let backend = B::fresh(db).await;
        dispatch(&backend, REGISTER, register("CUST-0017")).await;
        let before = backend.observe().await;

        let held = backend.hold_domain_lock().await;
        let read = tokio::time::timeout(Duration::from_secs(10), backend.read())
            .await
            .expect("a read must not wait for the domain lock")
            .unwrap();
        backend.release_domain_lock(held).await;

        let keys: Vec<&String> = read["instances"].as_object().unwrap().keys().collect();
        assert!(keys.iter().any(|k| k.contains("CUST-0017")), "{keys:?}");
        assert_eq!(backend.observe().await, before);
    }

    pub(super) async fn a_read_replays_the_gap_after_the_snapshot_without_persisting_it<
        B: Backend,
    >(
        db: &str,
    ) {
        let backend = B::fresh(db).await;
        dispatch(&backend, REGISTER, register("CUST-0018")).await;
        backend
            .append_unsnapshotted(REGISTER, &register("CUST-0019"))
            .await;
        let before = backend.observe().await;

        let read = backend.read().await.unwrap();

        let keys: Vec<&String> = read["instances"].as_object().unwrap().keys().collect();
        assert!(keys.iter().any(|k| k.contains("CUST-0018")), "{keys:?}");
        assert!(
            keys.iter().any(|k| k.contains("CUST-0019")),
            "the gap row is read: {keys:?}"
        );
        assert_eq!(
            backend.observe().await,
            before,
            "a read never closes the gap"
        );
    }

    pub(super) async fn a_dispatch_waits_for_the_domain_lock_while_readers_proceed<B: Backend>(
        db: &str,
    ) {
        let backend = B::fresh(db).await;
        let other = backend.sibling().await;
        dispatch(&backend, REGISTER, register("CUST-0020")).await;

        let held = backend.hold_domain_lock().await;
        let mut pending =
            Box::pin(other.dispatch_as(REGISTER, register("CUST-0021"), Caller::default()));
        let waited = tokio::time::timeout(Duration::from_millis(400), &mut pending).await;
        assert!(
            waited.is_err(),
            "the writer must wait for the holder of the lock"
        );
        assert_eq!(
            backend.observe().await.journal.len(),
            1,
            "and has written nothing yet"
        );
        backend.read().await.unwrap();

        backend.release_domain_lock(held).await;
        let outcome = pending.await.unwrap();
        assert!(outcome.accepted, "{:?}", outcome.result);
        assert_eq!(backend.observe().await.journal.len(), 2);
    }

    pub(super) async fn concurrent_dispatches_on_one_domain_never_interleave<B: Backend>(db: &str) {
        // Without the lock, two writers could both replay against zero prior steps, both see no
        // conflict and both append, breaking the uniqueness the domain enforces: exactly one of
        // two duplicate registrations may be accepted.
        let first = B::fresh(db).await;
        let second = first.sibling().await;
        for round in 0..4 {
            let reference = format!("CUST-RACE-{round}");
            let (a, b) = tokio::join!(
                first.dispatch_as(REGISTER, register(&reference), Caller::default()),
                second.dispatch_as(REGISTER, register(&reference), Caller::default()),
            );
            let (a, b) = (a.unwrap(), b.unwrap());
            assert_ne!(
                a.accepted, b.accepted,
                "round {round}: {:?} / {:?}",
                a.result, b.result
            );
            assert_eq!(first.observe().await.journal.len(), round + 1);
        }
    }

    pub(super) async fn a_dropped_unit_writes_nothing_and_frees_the_lock<B: Backend>(db: &str) {
        let backend = B::fresh(db).await;
        let other = backend.sibling().await;
        let before = backend.observe().await;

        let unit = backend.store().begin(DOMAIN).await.unwrap();
        unit.load().await.unwrap();
        drop(unit);

        assert_eq!(
            backend.observe().await,
            before,
            "a unit never committed wrote nothing"
        );
        let next = other.dispatch_as(REGISTER, register("CUST-0040"), Caller::default());
        let outcome = tokio::time::timeout(Duration::from_secs(10), next)
            .await
            .expect("the dropped unit must have released the domain lock")
            .unwrap();
        assert!(outcome.accepted, "{:?}", outcome.result);
    }

    pub(super) async fn sagas_load_in_key_order_however_they_were_written<B: Backend>(db: &str) {
        let backend = B::fresh(db).await;
        let saga = |correlation: &str, state: &str| journal::SagaRow {
            process_manager: "Settlement".to_string(),
            correlation: correlation.to_string(),
            state: state.to_string(),
            memory: json!({}),
            completed_compensations: json!([]),
        };
        let written = register("CUST-0043");
        let out_of_order = Accepted {
            verb: REGISTER,
            args: &written,
            new_seed: json!({}),
            saga_upserts: vec![
                saga("tr-b", "requested"),
                saga("tr-c", "requested"),
                saga("tr-a", "requested"),
            ],
            saga_deletes: Vec::new(),
            lineage: None,
        };
        let unit = backend.store().begin(DOMAIN).await.unwrap();
        unit.commit(out_of_order).await.unwrap();

        // Rewriting a row moves it in a heap, which is how a scan comes to disagree with the keys.
        let later = register("CUST-0044");
        let rewrite = Accepted {
            verb: REGISTER,
            args: &later,
            new_seed: json!({}),
            saga_upserts: vec![saga("tr-a", "settled")],
            saga_deletes: Vec::new(),
            lineage: None,
        };
        let unit = backend.store().begin(DOMAIN).await.unwrap();
        unit.commit(rewrite).await.unwrap();

        let unit = backend.store().begin(DOMAIN).await.unwrap();
        let loaded = unit.load().await.unwrap().sagas;
        let keys: Vec<&str> = loaded.iter().map(|s| s.correlation.as_str()).collect();
        assert_eq!(keys, ["tr-a", "tr-b", "tr-c"]);
    }

    fn heads_config(era: Option<i32>) -> LineageConfig {
        LineageConfig {
            domain: DOMAIN.to_string(),
            era,
            mirrored: None,
            seal_every: None,
        }
    }

    fn member(email: &str, role: &str) -> Value {
        json!({ "email": { "value": email }, "role": { "value": role } })
    }

    async fn save_head(store: &Store, id: &str, state: &Value) {
        let mutation = journal::Mutation {
            aggregate: "Customer",
            id,
            operation: "save",
            state,
        };
        store
            .put_head(&heads_config(Some(1)), &mutation)
            .await
            .unwrap();
    }

    pub(super) async fn a_saved_head_is_read_back_by_id_and_in_full<B: Backend>(db: &str) {
        let backend = B::fresh(db).await;
        let store = backend.store();
        assert_eq!(
            store.head_by_id(DOMAIN, "customer", "a").await.unwrap(),
            None
        );

        save_head(store, "a", &member("a@x.test", "viewer")).await;
        save_head(store, "b", &member("b@x.test", "viewer")).await;
        save_head(store, "a", &member("a@x.test", "admin")).await;

        assert_eq!(
            store.head_by_id(DOMAIN, "customer", "a").await.unwrap(),
            Some(member("a@x.test", "admin")),
            "a later save of one id replaces its head"
        );
        assert_eq!(
            store.head_all(DOMAIN, "customer").await.unwrap(),
            vec![
                ("a".to_string(), member("a@x.test", "admin")),
                ("b".to_string(), member("b@x.test", "viewer")),
            ]
        );
    }

    pub(super) async fn a_head_is_found_by_the_fields_it_holds<B: Backend>(db: &str) {
        let backend = B::fresh(db).await;
        let store = backend.store();
        save_head(store, "a", &member("a@x.test", "viewer")).await;
        save_head(store, "b", &member("b@x.test", "admin")).await;

        let found = |matches: Vec<(&'static str, &'static str)>| async move {
            store
                .head_find(&[DOMAIN], "customer", &matches)
                .await
                .unwrap()
        };
        assert_eq!(
            found(vec![("email", "b@x.test")]).await,
            Some(member("b@x.test", "admin"))
        );
        assert_eq!(
            found(vec![("email", "b@x.test"), ("role", "admin")]).await,
            Some(member("b@x.test", "admin"))
        );
        assert_eq!(
            found(vec![("email", "b@x.test"), ("role", "viewer")]).await,
            None
        );
        assert_eq!(found(vec![("email", "nobody@x.test")]).await, None);
    }

    pub(super) async fn an_amended_head_is_read_and_written_as_one_step<B: Backend>(db: &str) {
        let backend = B::fresh(db).await;
        let store = backend.store();
        let config = heads_config(Some(1));
        save_head(store, "a", &member("a@x.test", "viewer")).await;

        let seen = store
            .amend_head(&config, DOMAIN, "Customer", "customer", |rows| {
                (
                    rows.len(),
                    Some(("a".to_string(), member("a@x.test", "admin"))),
                )
            })
            .await
            .unwrap();
        assert_eq!(seen, 1, "the decision saw the head as committed");
        assert_eq!(
            store.head_by_id(DOMAIN, "customer", "a").await.unwrap(),
            Some(member("a@x.test", "admin"))
        );

        let declined = store
            .amend_head(&config, DOMAIN, "Customer", "customer", |_| ("no", None))
            .await
            .unwrap();
        assert_eq!(declined, "no");
        assert_eq!(
            store.head_all(DOMAIN, "customer").await.unwrap().len(),
            1,
            "a decision that writes nothing leaves the heads alone"
        );
    }

    pub(super) async fn the_first_domain_that_keeps_heads_answers_every_state<B: Backend>(
        db: &str,
    ) {
        let backend = B::fresh(db).await;
        let store = backend.store();
        assert!(store
            .head_states(&[DOMAIN, "Chapter"], "customer")
            .await
            .unwrap()
            .is_empty());

        save_head(store, "b", &member("b@x.test", "viewer")).await;
        save_head(store, "a", &member("a@x.test", "admin")).await;

        assert_eq!(
            store
                .head_states(&["Elsewhere", DOMAIN], "customer")
                .await
                .unwrap_or_default(),
            vec![member("a@x.test", "admin"), member("b@x.test", "viewer")],
            "in id order, from the first domain that has heads"
        );
    }

    pub(super) async fn held_eras_come_back_oldest_first_with_the_highest_as_current<B: Backend>(
        db: &str,
    ) {
        let backend = B::fresh(db).await;
        let store = backend.store();
        let before = store.held_eras(DOMAIN).await.unwrap();

        let first = backend.hold_era("shape-x").await;
        let second = backend.hold_era("shape-y").await;

        assert_eq!(second, first + 1, "each era takes the next ordinal");
        let held = store.held_eras(DOMAIN).await.unwrap();
        assert_eq!(held.len(), before.len() + 2);
        let ordinals: Vec<i32> = held.iter().map(|era| era.ordinal).collect();
        let mut sorted = ordinals.clone();
        sorted.sort_unstable();
        assert_eq!(ordinals, sorted, "oldest first");
        assert_eq!(held.last().unwrap().label.as_deref(), Some("shape-y"));
        assert_eq!(store.current_era(DOMAIN).await.unwrap(), Some(second));
    }

    pub(super) async fn a_domain_with_no_era_holds_none<B: Backend>(db: &str) {
        let backend = B::fresh(db).await;
        let store = backend.store();

        assert!(store.held_eras("Nowhere").await.unwrap().is_empty());
        assert_eq!(store.current_era("Nowhere").await.unwrap(), None);
    }

    pub(super) async fn a_head_write_without_an_era_is_refused_and_leaves_nothing<B: Backend>(
        db: &str,
    ) {
        let backend = B::fresh(db).await;
        let store = backend.store();
        let state = member("a@x.test", "viewer");
        let mutation = journal::Mutation {
            aggregate: "Customer",
            id: "a",
            operation: "save",
            state: &state,
        };

        assert!(store
            .put_head(&heads_config(None), &mutation)
            .await
            .is_err());
        let deleted = journal::Mutation {
            operation: "delete",
            ..mutation
        };
        assert!(store
            .put_head(&heads_config(Some(1)), &deleted)
            .await
            .is_err());
        assert!(store.head_all(DOMAIN, "customer").await.unwrap().is_empty());
    }

    pub(super) async fn a_unit_commits_a_saga_and_then_its_deletion<B: Backend>(db: &str) {
        let backend = B::fresh(db).await;
        let saga = |state: &str| journal::SagaRow {
            process_manager: "Settlement".to_string(),
            correlation: "tr-0041".to_string(),
            state: state.to_string(),
            memory: json!({}),
            completed_compensations: json!([]),
        };
        let first = register("CUST-0041");
        let accepted = Accepted {
            verb: REGISTER,
            args: &first,
            new_seed: json!({}),
            saga_upserts: vec![saga("requested")],
            saga_deletes: Vec::new(),
            lineage: None,
        };
        let unit = backend.store().begin(DOMAIN).await.unwrap();
        unit.commit(accepted).await.unwrap();

        let seen = backend.observe().await;
        assert_eq!(seen.sagas, vec![settlement("0041", "requested")]);
        let paired = seen.journal.last().map(|row| row.ordinal);
        assert_eq!(seen.snapshot.map(|s| s.ordinal), paired);

        let second = register("CUST-0042");
        let ending = Accepted {
            verb: REGISTER,
            args: &second,
            new_seed: json!({}),
            saga_upserts: Vec::new(),
            saga_deletes: vec![("Settlement".to_string(), "tr-0041".to_string())],
            lineage: None,
        };
        let unit = backend.store().begin(DOMAIN).await.unwrap();
        assert_eq!(
            unit.load().await.unwrap().sagas.len(),
            1,
            "the unit loads the live saga"
        );
        unit.commit(ending).await.unwrap();

        let seen = backend.observe().await;
        assert!(
            seen.sagas.is_empty(),
            "the ended saga is deleted with the command that ended it"
        );
        assert_eq!(seen.journal.len(), 2);
    }
}

/// Instantiates every case for one backend as its own test, each against a database of its own.
macro_rules! conformance_suite {
    ($backend:ty; $($case:ident),* $(,)?) => {
        $(
            #[tokio::test]
            async fn $case() {
                cases::$case::<$backend>(concat!("conf_", stringify!($case))).await;
            }
        )*
    };
}

struct PostgresBackend {
    db: String,
    client: Store,
    invoker: RecordingInvoker,
}

async fn connect(db: &str) -> Client {
    let (client, connection) = tokio_postgres::connect(&crate::test_pg::conninfo(db), NoTls)
        .await
        .expect("connect to the scratch database");
    tokio::spawn(async move {
        let _ = connection.await;
    });
    client
}

impl PostgresBackend {
    async fn rows(&self, sql: &str) -> Vec<tokio_postgres::Row> {
        self.client.lock().await.query(sql, &[]).await.unwrap()
    }

    async fn run(&self, sql: &str) {
        self.client.lock().await.batch_execute(sql).await.unwrap();
    }

    fn wrap(db: &str, client: Client) -> Self {
        Self {
            db: db.to_string(),
            client: crate::store::postgres_store(client),
            invoker: RecordingInvoker::new(),
        }
    }
}

/// The trigger body both injected faults share: any write to the table it guards is refused.
const REFUSE_WRITES: &str = "CREATE OR REPLACE FUNCTION conformance_refuse() RETURNS trigger AS \
    $$ BEGIN RAISE EXCEPTION 'injected write failure'; END $$ LANGUAGE plpgsql";

#[async_trait::async_trait]
impl Backend for PostgresBackend {
    type Held = Client;

    async fn fresh(name: &str) -> Self {
        // Each trait-level case name is the scratch database; `scratch_db` drops any leftover.
        let client = scratch_db(name).await;
        provision_lineage(
            &*client.lock().await,
            DOMAIN,
            1,
            &["Customer", "Account", "Transfer"],
        )
        .await;
        // The columns a minted `hecks_eras` carries beyond what the fixture creates.
        client
            .lock()
            .await
            .batch_execute(
                "ALTER TABLE hecks_eras ADD COLUMN IF NOT EXISTS label text, \
                 ADD COLUMN IF NOT EXISTS watermark bigint, \
                 ADD COLUMN IF NOT EXISTS held_digest text",
            )
            .await
            .unwrap();
        // The head view a minted era leaves over each aggregate's era-1 snapshot table.
        for storage in ["customer", "account", "transfer"] {
            let snapshot = journal::qualified_name(DOMAIN, &format!("{storage}_head_snapshot_1"));
            let view = journal::head_view(DOMAIN, storage);
            client
                .lock()
                .await
                .batch_execute(&format!(
                    "CREATE VIEW {} AS SELECT id, state FROM {}",
                    journal::quote_ident(&view),
                    journal::quote_ident(&snapshot)
                ))
                .await
                .unwrap();
        }
        Self {
            db: name.to_string(),
            client,
            invoker: RecordingInvoker::new(),
        }
    }

    async fn sibling(&self) -> Self {
        Self::wrap(&self.db, connect(&self.db).await)
    }

    async fn dispatch_as(
        &self,
        verb: &str,
        args: Value,
        caller: Caller<'_>,
    ) -> anyhow::Result<Outcome> {
        let (wasm, config) = (wasm_path(), test_config(DOMAIN, 1));
        let host = Host::new(&self.client, &wasm, &config, &self.invoker);
        dispatch::handle_as(host, verb, args, caller).await
    }

    async fn read(&self) -> anyhow::Result<Value> {
        dispatch::read(&self.client, &wasm_path()).await
    }

    fn store(&self) -> &Store {
        &self.client
    }

    async fn observe(&self) -> Observed {
        let journal = self
            .rows("SELECT ordinal, verb, args FROM hecks_lambda_journal ORDER BY ordinal")
            .await;
        let snapshot = self
            .rows("SELECT ordinal, seed, sagas_backfilled FROM hecks_lambda_snapshot")
            .await;
        let sagas = self
            .rows(
                "SELECT process_manager, correlation, state FROM hecks_lambda_sagas ORDER BY 1, 2",
            )
            .await;
        let lineage = self
            .rows("SELECT count(*) FROM hecks_journal_banking")
            .await;
        Observed {
            journal: journal
                .iter()
                .map(|r| JournalRow {
                    ordinal: r.get(0),
                    verb: r.get(1),
                    args: r.get(2),
                })
                .collect(),
            snapshot: snapshot.first().map(|r| SnapshotRow {
                ordinal: r.get(0),
                seed: r.get(1),
                sagas_backfilled: r.get(2),
            }),
            sagas: sagas
                .iter()
                .map(|r| SagaRow {
                    process_manager: r.get(0),
                    correlation: r.get(1),
                    state: r.get(2),
                })
                .collect(),
            lineage_rows: Some(lineage[0].get(0)),
        }
    }

    async fn append_unsnapshotted(&self, verb: &str, args: &Value) {
        let client = self.client.lock().await;
        let sql = "INSERT INTO hecks_lambda_journal (verb, args) VALUES ($1, $2)";
        client.execute(sql, &[&verb, args]).await.unwrap();
    }

    async fn damage_snapshot(&self) {
        let seed = self
            .observe()
            .await
            .snapshot
            .expect("a snapshot to damage")
            .seed;
        let mut damaged = seed;
        let record = damaged
            .as_object_mut()
            .unwrap()
            .values_mut()
            .next()
            .unwrap();
        assert!(
            record.as_object_mut().unwrap().remove("status").is_some(),
            "{record}"
        );
        let client = self.client.lock().await;
        client
            .execute("UPDATE hecks_lambda_snapshot SET seed = $1", &[&damaged])
            .await
            .unwrap();
    }

    async fn forget_saga_backfill(&self) {
        self.run("UPDATE hecks_lambda_snapshot SET sagas_backfilled = false")
            .await;
        self.run("DELETE FROM hecks_lambda_sagas").await;
    }

    /// A trigger that raises on the guarded table makes that write fail inside the open
    /// transaction, after the writes that precede it, so the rollback is what the case observes.
    async fn inject(&self, fault: Fault) {
        let table = match fault {
            Fault::SnapshotWrite => "hecks_lambda_snapshot",
            Fault::LineageWrite => "hecks_journal_banking",
        };
        self.run(REFUSE_WRITES).await;
        self.run(&format!(
            "CREATE TRIGGER conformance_fault BEFORE INSERT OR UPDATE ON {table} \
             FOR EACH ROW EXECUTE FUNCTION conformance_refuse()"
        ))
        .await;
    }

    async fn clear_faults(&self) {
        self.run("DROP TRIGGER IF EXISTS conformance_fault ON hecks_lambda_snapshot")
            .await;
        self.run("DROP TRIGGER IF EXISTS conformance_fault ON hecks_journal_banking")
            .await;
    }

    /// A second connection takes the same advisory lock a dispatch takes and keeps its
    /// transaction open.
    async fn hold_era(&self, label: &str) -> i32 {
        let row = self
            .client
            .lock()
            .await
            .query_one(
                "INSERT INTO hecks_eras (domain, ordinal, held_text, label) \
                 SELECT $1::text, COALESCE(MAX(ordinal), 0) + 1, 'test', $2::text \
                 FROM hecks_eras WHERE domain = $1::text RETURNING ordinal",
                &[&DOMAIN, &label],
            )
            .await
            .unwrap();
        row.get(0)
    }

    async fn hold_domain_lock(&self) -> Client {
        let competitor = connect(&self.db).await;
        competitor.batch_execute("BEGIN").await.unwrap();
        let lock = "SELECT pg_advisory_xact_lock(hashtext('hecks_lambda_journal.' || $1::text))";
        competitor.execute(lock, &[&DOMAIN]).await.unwrap();
        competitor
    }

    async fn release_domain_lock(&self, held: Client) {
        held.batch_execute("ROLLBACK").await.unwrap();
    }
}

mod postgres {
    use super::*;
    #[allow(unused_imports)]
    use crate::store::StoreFixtures;

    conformance_suite!(PostgresBackend;
        sagas_load_in_key_order_however_they_were_written,
        an_accepted_command_appends_one_journal_row,
        a_snapshot_and_a_gap_replay_to_the_state_of_a_full_replay,
        the_journal_keeps_arguments_as_recorded_and_never_restamps,
        a_refused_command_changes_nothing,
        a_kernel_failure_is_an_error_and_changes_nothing,
        a_snapshot_write_that_fails_leaves_the_append_invisible,
        a_saga_is_stored_with_the_command_that_produced_it,
        a_saga_write_rolls_back_with_a_command_that_fails,
        a_missing_backfill_latch_forces_one_full_replay,
        a_read_takes_no_lock_and_never_writes,
        a_read_replays_the_gap_after_the_snapshot_without_persisting_it,
        a_dispatch_waits_for_the_domain_lock_while_readers_proceed,
        concurrent_dispatches_on_one_domain_never_interleave,
        a_dropped_unit_writes_nothing_and_frees_the_lock,
        a_saved_head_is_read_back_by_id_and_in_full,
        a_head_is_found_by_the_fields_it_holds,
        an_amended_head_is_read_and_written_as_one_step,
        the_first_domain_that_keeps_heads_answers_every_state,
        held_eras_come_back_oldest_first_with_the_highest_as_current,
        a_domain_with_no_era_holds_none,
        a_head_write_without_an_era_is_refused_and_leaves_nothing,
        a_unit_commits_a_saga_and_then_its_deletion,
    );
}

struct MemoryBackend {
    memory: MemoryStore,
    store: Store,
    invoker: RecordingInvoker,
}

impl MemoryBackend {
    fn over(memory: MemoryStore) -> Self {
        Self {
            store: Store::memory(memory.clone()),
            memory,
            invoker: RecordingInvoker::new(),
        }
    }
}

#[async_trait::async_trait]
impl Backend for MemoryBackend {
    type Held = tokio::sync::OwnedMutexGuard<()>;

    async fn fresh(_name: &str) -> Self {
        Self::over(MemoryStore::new())
    }

    async fn sibling(&self) -> Self {
        Self::over(self.memory.clone())
    }

    async fn dispatch_as(
        &self,
        verb: &str,
        args: Value,
        caller: Caller<'_>,
    ) -> anyhow::Result<Outcome> {
        let config = LineageConfig {
            domain: DOMAIN.to_string(),
            era: None,
            mirrored: None,
            seal_every: None,
        };
        let wasm = wasm_path();
        let host = Host::new(&self.store, &wasm, &config, &self.invoker);
        dispatch::handle_as(host, verb, args, caller).await
    }

    async fn read(&self) -> anyhow::Result<Value> {
        dispatch::read(&self.store, &wasm_path()).await
    }

    fn store(&self) -> &Store {
        &self.store
    }

    async fn observe(&self) -> Observed {
        let (journal, snapshot, sagas) = self.memory.committed();
        Observed {
            journal: journal
                .into_iter()
                .map(|(ordinal, verb, args)| JournalRow {
                    ordinal,
                    verb,
                    args,
                })
                .collect(),
            snapshot: snapshot.map(|s| SnapshotRow {
                ordinal: s.ordinal,
                seed: s.seed,
                sagas_backfilled: s.sagas_backfilled,
            }),
            sagas: sagas
                .into_iter()
                .map(|s| SagaRow {
                    process_manager: s.process_manager,
                    correlation: s.correlation,
                    state: s.state,
                })
                .collect(),
            lineage_rows: None,
        }
    }

    async fn append_unsnapshotted(&self, verb: &str, args: &Value) {
        self.memory.append_unsnapshotted(verb, args);
    }

    async fn damage_snapshot(&self) {
        let mut seed = self
            .observe()
            .await
            .snapshot
            .expect("a snapshot to damage")
            .seed;
        let record = seed.as_object_mut().unwrap().values_mut().next().unwrap();
        let removed = record.as_object_mut().unwrap().remove("status");
        assert!(removed.is_some(), "{record}");
        self.memory.replace_seed(seed);
    }

    async fn forget_saga_backfill(&self) {
        self.memory.forget_saga_backfill();
    }

    async fn inject(&self, fault: Fault) {
        self.memory.inject_fault(match fault {
            Fault::SnapshotWrite => MemoryFault::Snapshot,
            Fault::LineageWrite => MemoryFault::AfterSagas,
        });
    }

    async fn clear_faults(&self) {
        self.memory.clear_fault();
    }

    async fn hold_era(&self, label: &str) -> i32 {
        self.memory.hold_era(DOMAIN, label)
    }

    async fn hold_domain_lock(&self) -> Self::Held {
        self.memory.hold_lock().await
    }

    async fn release_domain_lock(&self, held: Self::Held) {
        drop(held);
    }
}

mod memory {
    use super::*;
    #[allow(unused_imports)]
    use crate::store::StoreFixtures;

    conformance_suite!(MemoryBackend;
        sagas_load_in_key_order_however_they_were_written,
        an_accepted_command_appends_one_journal_row,
        a_snapshot_and_a_gap_replay_to_the_state_of_a_full_replay,
        the_journal_keeps_arguments_as_recorded_and_never_restamps,
        a_refused_command_changes_nothing,
        a_kernel_failure_is_an_error_and_changes_nothing,
        a_snapshot_write_that_fails_leaves_the_append_invisible,
        a_saga_is_stored_with_the_command_that_produced_it,
        a_saga_write_rolls_back_with_a_command_that_fails,
        a_missing_backfill_latch_forces_one_full_replay,
        a_read_takes_no_lock_and_never_writes,
        a_read_replays_the_gap_after_the_snapshot_without_persisting_it,
        a_dispatch_waits_for_the_domain_lock_while_readers_proceed,
        concurrent_dispatches_on_one_domain_never_interleave,
        a_dropped_unit_writes_nothing_and_frees_the_lock,
        a_saved_head_is_read_back_by_id_and_in_full,
        a_head_is_found_by_the_fields_it_holds,
        an_amended_head_is_read_and_written_as_one_step,
        the_first_domain_that_keeps_heads_answers_every_state,
        held_eras_come_back_oldest_first_with_the_highest_as_current,
        a_domain_with_no_era_holds_none,
        a_head_write_without_an_era_is_refused_and_leaves_nothing,
        a_unit_commits_a_saga_and_then_its_deletion,
    );
}
