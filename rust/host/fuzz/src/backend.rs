//! The one seam both journal stores sit behind, and the two stores.
//!
//! [`MemoryBackend`] is the host's own `MemoryStore`, the in-memory adapter that already passes the
//! same conformance cases as Postgres, so it is the oracle and not a second mock to keep in step.
//! [`PostgresBackend`] keeps one connection for the life of the process and resets its tables
//! between scripts instead of provisioning a database per case.
//!
//! The wasm kernel is compiled once per process by `rust_host::wasm_runner`, so the only per-script
//! work left in either backend is the kernel's replay and the store's writes.

use anyhow::Context;
use rust_host::dispatch::{self, Caller};
use rust_host::host::Host;
use rust_host::journal::{self, LineageConfig};
use rust_host::lambda_client::{InvokeOutcome, LambdaInvoker};
use rust_host::store::{MemoryStore, Store};
use serde_json::Value;
use std::path::PathBuf;
use std::sync::{Arc, Mutex, PoisonError};
use tokio_postgres::NoTls;

/// The domain the compiled kernel under test belongs to.
pub const DOMAIN: &str = "Banking";

/// The tables a script writes, truncated together between scripts.
const TABLES: [&str; 4] = [
    "hecks_lambda_journal",
    "hecks_lambda_snapshot",
    "hecks_lambda_sagas",
    "hecks_cross_domain_dead_letters",
];

/// What one dispatch answered, reduced to what two stores must agree on.
#[derive(Debug, Clone, PartialEq)]
pub enum Step {
    Accepted(Value),
    Refused(Value),
    /// The dispatch failed outright. Only the fact is compared: a backend's error text is its own.
    Failed,
}

impl Step {
    #[must_use]
    pub const fn accepted(&self) -> bool {
        matches!(self, Self::Accepted(_))
    }
}

/// What a second reader would see in the store after a script.
#[derive(Debug, Clone, PartialEq)]
pub struct Observed {
    /// The ordinal the snapshot is paired with, which counts the accepted commands.
    pub snapshot_ordinal: Option<i64>,
    pub seed: Value,
    /// `(process_manager, correlation, state)`, sorted.
    pub sagas: Vec<(String, String, String)>,
}

/// A journal store the host can dispatch against.
#[allow(async_fn_in_trait)] // the harness drives one backend at a time on one thread
pub trait Backend {
    /// Empties the store so the next script starts from nothing.
    async fn reset(&self) -> anyhow::Result<()>;
    async fn dispatch(&self, verb: &str, args: Value) -> Step;
    async fn observe(&self) -> anyhow::Result<Observed>;
}

/// The path of the compiled kernel: `HECKS_FUZZ_WASM`, else `rust/dist/banking.wasm`.
fn wasm_path() -> PathBuf {
    std::env::var_os("HECKS_FUZZ_WASM").map_or_else(
        || PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../dist/banking.wasm"),
        PathBuf::from,
    )
}

/// Banking's `ReviewOnFreeze` policy delivers to the Compliance domain's function. Nothing is
/// deployed here, so every delivery is answered the way the host's own tests answer it: delivered,
/// nothing refused. Both stores get the same answer, so a delivery never explains a difference.
struct AcceptDelivery;

#[async_trait::async_trait]
impl LambdaInvoker for AcceptDelivery {
    async fn invoke(&self, _function_name: &str, _payload: &str) -> anyhow::Result<InvokeOutcome> {
        Ok(InvokeOutcome {
            body: serde_json::json!({ "refusals": [] }),
            function_error: false,
        })
    }
}

/// The saga lists of an outcome, which come back in the order the store loaded the sagas.
/// `PostgresStore` loads them with no `ORDER BY` (`journal.rs`, `SELECT ... FROM hecks_lambda_sagas`)
/// while `MemoryStore` keeps them sorted, so the two disagree on order alone. Until that load is
/// ordered they are compared as sets, and this is the only place the harness looks away.
const UNORDERED: [&str; 2] = ["sagas", "saga_snapshot"];

/// Every event carries the wall-clock second it ran (`occurred_at`), and the two stores are played
/// moments apart, so the stamp is dropped before outcomes are compared.
fn timeless(mut value: Value) -> Value {
    match &mut value {
        Value::Object(map) => {
            map.remove("occurred_at");
            for (key, child) in map.iter_mut() {
                *child = timeless(child.take());
                if let (true, Value::Array(items)) =
                    (UNORDERED.contains(&key.as_str()), &mut *child)
                {
                    items.sort_by_key(ToString::to_string);
                }
            }
        }
        Value::Array(items) => items.iter_mut().for_each(|v| *v = timeless(v.take())),
        _ => {}
    }
    value
}

/// A store, the kernel path and the lineage config a dispatch needs.
struct Hosted {
    store: Store,
    wasm: PathBuf,
    config: LineageConfig,
}

impl Hosted {
    fn new(store: Store) -> Self {
        let config = LineageConfig {
            domain: DOMAIN.to_string(),
            era: None,
            mirrored: None,
        };
        Self {
            store,
            wasm: wasm_path(),
            config,
        }
    }

    async fn dispatch(&self, verb: &str, args: Value) -> Step {
        let host = Host::new(&self.store, &self.wasm, &self.config, &AcceptDelivery);
        match dispatch::handle_as(host, verb, args, Caller::default()).await {
            Ok(outcome) if outcome.accepted => Step::Accepted(timeless(outcome.result)),
            Ok(outcome) => Step::Refused(timeless(outcome.result)),
            Err(_) => Step::Failed,
        }
    }

    /// Reads inside a unit that is dropped uncommitted, so nothing is written and the lock is freed.
    async fn observe(&self) -> anyhow::Result<Observed> {
        let unit = self
            .store
            .begin(DOMAIN)
            .await
            .map_err(|e| anyhow::anyhow!("{e}"))?;
        let state = unit.load().await.map_err(|e| anyhow::anyhow!("{e}"))?;
        let mut sagas: Vec<_> = state
            .sagas
            .iter()
            .map(|s| {
                (
                    s.process_manager.clone(),
                    s.correlation.clone(),
                    s.state.clone(),
                )
            })
            .collect();
        sagas.sort();
        Ok(Observed {
            snapshot_ordinal: state.snapshot.as_ref().map(|s| s.ordinal),
            seed: state
                .snapshot
                .map_or_else(|| Value::Object(serde_json::Map::new()), |s| s.seed),
            sagas,
        })
    }
}

/// The host's in-memory store. A fresh one costs an allocation, so [`Backend::reset`] swaps it.
pub struct MemoryBackend {
    hosted: Mutex<Arc<Hosted>>,
}

impl MemoryBackend {
    #[must_use]
    pub fn new() -> Self {
        Self {
            hosted: Mutex::new(Self::fresh()),
        }
    }

    fn fresh() -> Arc<Hosted> {
        Arc::new(Hosted::new(Store::memory(MemoryStore::new())))
    }

    fn current(&self) -> Arc<Hosted> {
        Arc::clone(&self.hosted.lock().unwrap_or_else(PoisonError::into_inner))
    }
}

impl Default for MemoryBackend {
    fn default() -> Self {
        Self::new()
    }
}

impl Backend for MemoryBackend {
    async fn reset(&self) -> anyhow::Result<()> {
        *self.hosted.lock().unwrap_or_else(PoisonError::into_inner) = Self::fresh();
        Ok(())
    }

    async fn dispatch(&self, verb: &str, args: Value) -> Step {
        self.current().dispatch(verb, args).await
    }

    async fn observe(&self) -> anyhow::Result<Observed> {
        self.current().observe().await
    }
}

/// The host's Postgres store over one connection that lives as long as the process.
///
/// The session is tuned for a scratch database whose only job is to agree with the oracle: commits
/// do not wait for the WAL (`synchronous_commit = off`) and the tables are unlogged, which removes
/// the fsync a durable store pays on every accepted command. It follows that this backend says
/// nothing about crash durability, only about what the store holds once a command has committed.
pub struct PostgresBackend {
    hosted: Hosted,
    /// A second connection that only truncates, because the store keeps its own to itself.
    resetter: tokio_postgres::Client,
}

impl PostgresBackend {
    /// Connects with a libpq-style `conninfo`, creates the host's tables if they are missing and
    /// tunes the session.
    ///
    /// # Errors
    ///
    /// Returns the connection or DDL error.
    pub async fn connect(conninfo: &str) -> anyhow::Result<Self> {
        let (client, connection) = tokio_postgres::connect(conninfo, NoTls)
            .await
            .with_context(|| format!("connecting to {conninfo}"))?;
        tokio::spawn(async move {
            let _ = connection.await;
        });
        journal::ensure_schema(&client).await?;
        client.batch_execute("SET synchronous_commit = off").await?;
        for table in TABLES {
            client
                .batch_execute(&format!("ALTER TABLE {table} SET UNLOGGED"))
                .await?;
        }
        Ok(Self {
            hosted: Hosted::new(Store::postgres(client)),
            resetter: Self::open(conninfo).await?,
        })
    }

    async fn open(conninfo: &str) -> anyhow::Result<tokio_postgres::Client> {
        let (client, connection) = tokio_postgres::connect(conninfo, NoTls).await?;
        tokio::spawn(async move {
            let _ = connection.await;
        });
        client.batch_execute("SET synchronous_commit = off").await?;
        Ok(client)
    }
}

impl Backend for PostgresBackend {
    async fn reset(&self) -> anyhow::Result<()> {
        let sql = format!("TRUNCATE {} RESTART IDENTITY", TABLES.join(", "));
        self.resetter.batch_execute(&sql).await?;
        Ok(())
    }

    async fn dispatch(&self, verb: &str, args: Value) -> Step {
        self.hosted.dispatch(verb, args).await
    }

    async fn observe(&self) -> anyhow::Result<Observed> {
        self.hosted.observe().await
    }
}
