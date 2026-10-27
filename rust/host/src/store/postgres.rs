//! The Postgres backend: one connection, one transaction per [`Unit`].
//!
//! The domain lock is a transaction-scoped advisory lock, and the `journal.rs` functions run
//! the SQL unchanged inside the open transaction.

use super::{Accepted, DeadLetter, State, StoreError};
use crate::journal;
use std::future::Future;
use std::sync::Arc;
use std::task::{Context, Poll, Waker};
use tokio::sync::{Mutex, MutexGuard};
use tokio_postgres::Client;

/// A domain's journal, snapshot and sagas in Postgres tables, over one connection.
pub struct PostgresStore {
    lineage: LineageStore,
}

/// The era, head-view and member-lookup surface of a Postgres store: the part of the host that
/// reads and writes the lineage relations directly, and so has no other backend.
pub struct LineageStore {
    client: Arc<Mutex<Client>>,
}

impl LineageStore {
    /// The one connection, held for as long as the guard lives; its mutex serializes every use.
    pub async fn lock(&self) -> MutexGuard<'_, Client> {
        self.client.lock().await
    }
}

impl PostgresStore {
    /// A store over `client`, which every use of this store shares.
    #[must_use]
    pub fn new(client: Client) -> Self {
        Self {
            lineage: LineageStore {
                client: Arc::new(Mutex::new(client)),
            },
        }
    }

    /// The lineage surface over the same connection.
    pub(super) const fn lineage(&self) -> &LineageStore {
        &self.lineage
    }

    /// Opens a transaction and takes the advisory lock for `domain` inside it.
    ///
    /// The lock covers the whole read-then-append sequence, not just the insert: two concurrent
    /// invocations could otherwise both replay the same prior steps and both pass a uniqueness
    /// check the domain thinks it is enforcing. It is scoped to the domain so unrelated domains
    /// sharing one Postgres instance do not serialize against each other.
    pub(super) async fn begin(&self, domain: &str) -> Result<PostgresUnit<'_>, StoreError> {
        let guard = self.lineage.client.lock().await;
        let mut unit = PostgresUnit { guard, open: false };
        unit.guard.batch_execute("BEGIN").await?;
        unit.open = true;
        unit.guard
            .execute(
                "SELECT pg_advisory_xact_lock(hashtext('hecks_lambda_journal.' || $1::text))",
                &[&domain],
            )
            .await?;
        Ok(unit)
    }

    /// The snapshot and the steps after it (or every step), read without the domain lock.
    pub(super) async fn read_state(&self) -> Result<State, StoreError> {
        let guard = self.lineage.client.lock().await;
        let snapshot = journal::load_snapshot(&*guard).await?;
        let steps = match &snapshot {
            Some(s) => journal::load_steps_after(&*guard, s.ordinal).await?,
            None => journal::load_steps(&*guard).await?,
        };
        Ok(State {
            snapshot,
            steps,
            sagas: Vec::new(),
        })
    }

    /// Inserts the dead-letter row on the shared connection, outside any transaction.
    pub(super) async fn record_dead_letter(
        &self,
        dead_letter: &DeadLetter<'_>,
    ) -> Result<(), StoreError> {
        let guard = self.lineage.client.lock().await;
        journal::record_dead_letter(
            &*guard,
            dead_letter.policy,
            dead_letter.target_domain,
            dead_letter.target_verb,
            dead_letter.payload,
            dead_letter.error,
            dead_letter.attempts,
        )
        .await?;
        Ok(())
    }
}

/// One open transaction holding the domain's advisory lock and the connection's mutex.
///
/// Dropping it without committing rolls the transaction back, which also releases the lock.
pub struct PostgresUnit<'a> {
    guard: MutexGuard<'a, Client>,
    open: bool,
}

impl PostgresUnit<'_> {
    /// Loads snapshot, replay steps and sagas inside the open transaction.
    pub(super) async fn load(&self) -> Result<State, StoreError> {
        let snapshot = journal::load_snapshot(&*self.guard).await?;
        let mut state = State {
            snapshot,
            steps: Vec::new(),
            sagas: Vec::new(),
        };
        state.steps = match &state.snapshot {
            Some(s) if !state.needs_saga_backfill() => {
                journal::load_steps_after(&*self.guard, s.ordinal).await?
            }
            _ => journal::load_steps(&*self.guard).await?,
        };
        state.sagas = journal::load_sagas(&*self.guard).await?;
        Ok(state)
    }

    /// Writes the journal row, snapshot, sagas and lineage mutations, then commits.
    pub(super) async fn commit(mut self, accepted: Accepted<'_>) -> Result<(), StoreError> {
        let client = &*self.guard;
        let ordinal = journal::append(client, accepted.verb, accepted.args).await?;
        journal::save_snapshot(client, ordinal, &accepted.new_seed).await?;
        for saga in &accepted.saga_upserts {
            journal::save_saga(
                client,
                &saga.process_manager,
                &saga.correlation,
                &saga.state,
                &saga.memory,
                &saga.completed_compensations,
            )
            .await?;
        }
        for (process_manager, correlation) in &accepted.saga_deletes {
            journal::delete_saga(client, process_manager, correlation).await?;
        }
        if let Some(lineage) = &accepted.lineage {
            for mutation in &lineage.mutations {
                journal::append_lineage_mutation(client, lineage.config, mutation).await?;
            }
            // Sealed here, under the domain lock and inside the transaction, so the seal and the
            // rows it covers land together or not at all.
            if let Some(every) = lineage.config.seal_every {
                crate::ledger::seal_due(client, &lineage.config.domain, every).await?;
            }
        }
        client.batch_execute("COMMIT").await?;
        self.open = false;
        Ok(())
    }

    /// Rolls the transaction back and waits for the server to confirm.
    pub(super) async fn rollback(mut self) -> Result<(), StoreError> {
        self.guard.batch_execute("ROLLBACK").await?;
        self.open = false;
        Ok(())
    }
}

impl Drop for PostgresUnit<'_> {
    /// Sends the rollback of an unfinished transaction ahead of anything the next holder of
    /// the connection sends. Dropping cannot await, so the request is queued by polling the
    /// call once, the way `tokio_postgres::Transaction` rolls itself back.
    fn drop(&mut self) {
        if self.open {
            let mut rollback = Box::pin(self.guard.batch_execute("ROLLBACK"));
            let _: Poll<_> = rollback
                .as_mut()
                .poll(&mut Context::from_waker(Waker::noop()));
        }
    }
}
