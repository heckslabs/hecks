//! The Postgres side of the store: the backend, the journal's SQL and the era minting, over the
//! [`Store`] and [`Backend`] that `rust_host_core` owns.
//!
//! The core knows only the traits. A store over Postgres is made here, and the host crate's
//! tools (minting, the ledger, the harnesses) reach the connection through [`LineageStore`].

/// The journal's SQL: the Postgres adapter's reads and writes, with the journal's data re-exported.
pub mod journal_sql;
/// Era minting: the Postgres adapter's provisioning of eras, heads and lineage.
pub mod mint;
mod postgres;

pub use postgres::{LineageStore, PostgresStore, PostgresUnit};
pub use rust_host_core::store::*;
use tokio_postgres::Client;

/// A store over one Postgres connection, whose mutex serializes every use of it.
#[must_use]
pub fn postgres_store(client: Client) -> Store {
    Store::new(PostgresStore::new(client))
}

/// The Postgres reach into a [`Store`] that the core does not offer: the connection handle, and in
/// tests the raw rows beneath the seam.
pub trait StoreExt {
    /// The Postgres adapter's own connection handle, for minting, seals and operator tools; code
    /// that runs a domain uses the head methods and never this.
    fn lineage(&self) -> Option<&LineageStore>;
}

impl StoreExt for Store {
    fn lineage(&self) -> Option<&LineageStore> {
        self.backend()
            .as_any()
            .downcast_ref::<PostgresStore>()
            .map(PostgresStore::lineage)
    }
}

/// Raw access for test fixtures and assertions that reach beneath the seam.
#[cfg(test)]
#[allow(async_fn_in_trait)]
pub trait StoreFixtures {
    /// Every journaled step in order, whichever backend holds them.
    async fn journal_steps(&self) -> Vec<serde_json::Value>;
    /// Every dead letter as `(policy, target_domain, target_verb, attempts)`, ordered by policy.
    async fn dead_letter_rows(&self) -> Vec<(String, String, String, i32)>;
    /// The raw connection of a Postgres store.
    async fn lock(&self) -> tokio::sync::MutexGuard<'_, Client>;
}

#[cfg(test)]
impl StoreFixtures for Store {
    async fn journal_steps(&self) -> Vec<serde_json::Value> {
        if let Some(store) = self.backend().as_any().downcast_ref::<PostgresStore>() {
            let guard = store.lineage().lock().await;
            return journal_sql::load_steps(&*guard).await.unwrap();
        }
        let memory = self.backend().as_any().downcast_ref::<MemoryStore>();
        memory
            .expect("a Postgres or Memory store")
            .committed()
            .0
            .into_iter()
            .map(|(_, verb, args)| serde_json::json!({ "verb": verb, "args": args }))
            .collect()
    }

    async fn dead_letter_rows(&self) -> Vec<(String, String, String, i32)> {
        if let Some(store) = self.backend().as_any().downcast_ref::<PostgresStore>() {
            let guard = store.lineage().lock().await;
            let sql = "SELECT policy, target_domain, target_verb, attempts \
                       FROM hecks_cross_domain_dead_letters ORDER BY policy";
            let rows = guard.query(sql, &[]).await.unwrap();
            return rows
                .iter()
                .map(|r| (r.get(0), r.get(1), r.get(2), r.get(3)))
                .collect();
        }
        let memory = self.backend().as_any().downcast_ref::<MemoryStore>();
        let mut rows: Vec<_> = memory
            .expect("a Postgres or Memory store")
            .dead_letters()
            .into_iter()
            .map(|d| (d.policy, d.target_domain, d.target_verb, d.attempts))
            .collect();
        rows.sort();
        rows
    }

    async fn lock(&self) -> tokio::sync::MutexGuard<'_, Client> {
        match self.lineage() {
            Some(lineage) => lineage.lock().await,
            None => panic!("a memory store has no connection to lock"),
        }
    }
}
