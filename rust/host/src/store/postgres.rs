//! The Postgres backend: one connection, one transaction per [`Unit`].
//!
//! The domain lock is a transaction-scoped advisory lock, and the `journal.rs` functions run
//! the SQL unchanged inside the open transaction.

use super::{Accepted, DeadLetter, State, StoreError};
use crate::store::journal_sql as journal;
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
    /// Every live `state` document of the first head that exists, trying the head view of each of
    /// `domains` in turn, then the plain `<storage>_head` view and the plain table, because
    /// different runtimes have written these rows under different names. A relation that exists
    /// but fails to read still errors; none existing answers empty.
    pub async fn head_states(
        &self,
        domains: &[&str],
        storage_name: &str,
    ) -> anyhow::Result<Vec<serde_json::Value>> {
        let client = self.lock().await;
        for relation in head_relations(domains, storage_name) {
            // `to_regclass` resolves through the connection's own `search_path`, so a same-named
            // relation in another schema is never read.
            let exists: bool = client
                .query_one("SELECT to_regclass($1) IS NOT NULL", &[&relation])
                .await?
                .get(0);
            if !exists {
                continue;
            }
            let rows = client
                .query(
                    &format!(
                        "SELECT state FROM {} ORDER BY id COLLATE \"C\"",
                        journal::quote_ident(&relation)
                    ),
                    &[],
                )
                .await?;
            return Ok(rows.iter().map(|row| row.get(0)).collect());
        }
        Ok(Vec::new())
    }

    /// The head row whose `matches` fields all hold, read from the first of `domains` whose head
    /// view exists (then the plain `<storage>_head` view); that view decides, so a miss in it is
    /// `None` and the later views are not asked. Each match is `(field, value)`, comparing the
    /// field's single-attribute value object to `value`.
    pub async fn head_find(
        &self,
        domains: &[&str],
        storage_name: &str,
        matches: &[(&str, &str)],
    ) -> Result<Option<serde_json::Value>, StoreError> {
        let mut relations: Vec<String> = domains
            .iter()
            .map(|domain| journal::head_view(domain, storage_name))
            .collect();
        relations.push(format!("{storage_name}_head"));
        relations.dedup();
        let conditions: Vec<String> = matches
            .iter()
            .enumerate()
            .map(|(i, (field, _))| {
                format!(
                    "state->'{}'->>'value' = ${}",
                    field.replace('\'', "''"),
                    i + 1
                )
            })
            .collect();
        let values: Vec<&(dyn tokio_postgres::types::ToSql + Sync)> = matches
            .iter()
            .map(|(_, value)| value as &(dyn tokio_postgres::types::ToSql + Sync))
            .collect();
        let client = self.lock().await;
        for relation in relations {
            let sql = format!(
                "SELECT state FROM {} WHERE {}",
                journal::quote_ident(&relation),
                conditions.join(" AND ")
            );
            match client.query_opt(&sql, &values).await {
                Ok(row) => return Ok(row.map(|row| row.get(0))),
                Err(e) => {
                    let e = pg(e);
                    if !e.is_not_provisioned() {
                        return Err(e);
                    }
                }
            }
        }
        Ok(None)
    }

    /// Writes one head row under the domain's ordinal lock, in a transaction of its own.
    pub async fn put_head(
        &self,
        config: &journal::LineageConfig,
        mutation: &journal::Mutation<'_>,
    ) -> anyhow::Result<()> {
        let mut client = self.lock().await;
        let txn = client.transaction().await?;
        txn.execute(
            "SELECT pg_advisory_xact_lock(hashtext('hecks_ordinal:' || $1))",
            &[&config.domain],
        )
        .await?;
        journal::append_lineage_mutation(&txn, config, mutation).await?;
        txn.commit().await?;
        Ok(())
    }

    /// Reads one aggregate's head rows and lets `decide` answer with at most one `(id, state)`
    /// to write, all under the domain's ordinal lock in one transaction; a `decide` that writes
    /// nothing leaves the heads untouched.
    pub async fn amend_head<T>(
        &self,
        config: &journal::LineageConfig,
        domain: &str,
        aggregate: &str,
        storage_name: &str,
        decide: impl FnOnce(&[(String, serde_json::Value)]) -> (T, Option<(String, serde_json::Value)>),
    ) -> anyhow::Result<T> {
        let mut client = self.lock().await;
        let txn = client.transaction().await?;
        txn.execute(
            "SELECT pg_advisory_xact_lock(hashtext('hecks_ordinal:' || $1))",
            &[&config.domain],
        )
        .await?;
        let rows = journal::read_lineage_head_all(&txn, domain, storage_name).await?;
        let (answer, write) = decide(&rows);
        if let Some((id, state)) = write {
            let mutation = journal::Mutation {
                aggregate,
                id: &id,
                operation: "save",
                state: &state,
            };
            journal::append_lineage_mutation(&txn, config, &mutation).await?;
            txn.commit().await?;
        }
        Ok(answer)
    }

    /// The one connection, held for as long as the guard lives; its mutex serializes every use.
    pub async fn lock(&self) -> MutexGuard<'_, Client> {
        self.client.lock().await
    }
}

impl PostgresStore {
    /// A store over `client`, which every use of this store shares.
    #[must_use]
    pub fn new(client: Client) -> Self {
        StoreError::teach_not_provisioned(is_missing_relation);
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
        unit.guard.batch_execute("BEGIN").await.map_err(pg)?;
        unit.open = true;
        unit.guard
            .execute(
                "SELECT pg_advisory_xact_lock(hashtext('hecks_lambda_journal.' || $1::text))",
                &[&domain],
            )
            .await
            .map_err(pg)?;
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
        client.batch_execute("COMMIT").await.map_err(pg)?;
        self.open = false;
        Ok(())
    }

    /// Rolls the transaction back and waits for the server to confirm.
    pub(super) async fn rollback(mut self) -> Result<(), StoreError> {
        self.guard.batch_execute("ROLLBACK").await.map_err(pg)?;
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

/// Whether a failure is Postgres reporting that a table or view does not exist.
fn is_missing_relation(error: &anyhow::Error) -> bool {
    error
        .chain()
        .filter_map(|cause| cause.downcast_ref::<tokio_postgres::Error>())
        .any(|db| db.code() == Some(&tokio_postgres::error::SqlState::UNDEFINED_TABLE))
}

/// Wraps a driver error as a store failure, keeping the not-provisioned test working.
fn pg(error: tokio_postgres::Error) -> StoreError {
    anyhow::Error::from(error).into()
}

/// The relations a head may live in, in the order they are tried: each domain's head view, the
/// plain `<storage>_head` view, then the plain table. Deduplicated, so a domain named twice never
/// probes one relation twice.
fn head_relations(domains: &[&str], storage_name: &str) -> Vec<String> {
    let mut relations: Vec<String> = domains
        .iter()
        .map(|domain| journal::head_view(domain, storage_name))
        .collect();
    relations.push(format!("{storage_name}_head"));
    relations.push(storage_name.to_string());
    relations.dedup();
    relations
}

#[async_trait::async_trait]
impl super::Backend for PostgresStore {
    async fn begin<'a>(
        &'a self,
        domain: &str,
    ) -> Result<Box<dyn super::UnitBackend + 'a>, StoreError> {
        Ok(Box::new(PostgresStore::begin(self, domain).await?))
    }

    async fn read_state(&self) -> Result<State, StoreError> {
        PostgresStore::read_state(self).await
    }

    async fn record_dead_letter(&self, dead_letter: &DeadLetter<'_>) -> Result<(), StoreError> {
        PostgresStore::record_dead_letter(self, dead_letter).await
    }

    async fn head_by_id(
        &self,
        domain: &str,
        storage_name: &str,
        id: &str,
    ) -> Result<Option<serde_json::Value>, StoreError> {
        let guard = self.lineage.lock().await;
        Ok(journal::read_lineage_head_by_id(&*guard, domain, storage_name, id).await?)
    }

    async fn head_all(
        &self,
        domain: &str,
        storage_name: &str,
    ) -> Result<Vec<(String, serde_json::Value)>, StoreError> {
        let guard = self.lineage.lock().await;
        Ok(journal::read_lineage_head_all(&*guard, domain, storage_name).await?)
    }

    async fn head_states(
        &self,
        domains: &[&str],
        storage_name: &str,
    ) -> Result<Vec<serde_json::Value>, StoreError> {
        Ok(self.lineage.head_states(domains, storage_name).await?)
    }

    async fn head_find(
        &self,
        domains: &[&str],
        storage_name: &str,
        matches: &[(&str, &str)],
    ) -> Result<Option<serde_json::Value>, StoreError> {
        self.lineage.head_find(domains, storage_name, matches).await
    }

    async fn put_head(
        &self,
        config: &journal::LineageConfig,
        mutation: &journal::Mutation<'_>,
    ) -> Result<(), StoreError> {
        Ok(self.lineage.put_head(config, mutation).await?)
    }

    async fn amend_head(
        &self,
        config: &journal::LineageConfig,
        domain: &str,
        aggregate: &str,
        storage_name: &str,
        decide: &mut (dyn for<'r> FnMut(
            &'r [(String, serde_json::Value)],
        ) -> Option<(String, serde_json::Value)>
                  + Send),
    ) -> Result<(), StoreError> {
        self.lineage
            .amend_head(
                config,
                domain,
                aggregate,
                storage_name,
                |rows: &[(String, serde_json::Value)]| ((), decide(rows)),
            )
            .await?;
        Ok(())
    }

    fn as_any(&self) -> &dyn std::any::Any {
        self
    }
}

#[async_trait::async_trait]
impl super::UnitBackend for PostgresUnit<'_> {
    async fn load(&self) -> Result<State, StoreError> {
        PostgresUnit::load(self).await
    }

    async fn commit(self: Box<Self>, accepted: Accepted<'_>) -> Result<(), StoreError> {
        (*self).commit(accepted).await
    }

    async fn rollback(self: Box<Self>) -> Result<(), StoreError> {
        (*self).rollback().await
    }
}

#[cfg(test)]
mod tests {
    use super::head_relations;

    #[test]
    fn head_relations_cover_every_relation_a_runtime_has_written_these_rows_to() {
        assert_eq!(
            head_relations(&["SampleApp", "ConsoleSettings"], "state_style"),
            vec![
                "sample_app_state_style_head".to_string(),
                "console_settings_state_style_head".to_string(),
                "state_style_head".to_string(),
                "state_style".to_string()
            ]
        );
    }

    #[test]
    fn a_domain_named_twice_never_probes_one_relation_twice() {
        assert_eq!(
            head_relations(&["ConsoleSettings", "ConsoleSettings"], "state_style"),
            vec![
                "console_settings_state_style_head".to_string(),
                "state_style_head".to_string(),
                "state_style".to_string()
            ]
        );
    }
}
