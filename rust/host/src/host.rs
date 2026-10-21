//! What a request handler needs to reach the domain, travelling as one value.

use crate::journal::LineageConfig;
use crate::lambda_client::LambdaInvoker;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use tokio::sync::Mutex;
use tokio_postgres::Client;

/// The server's own shared handles, when a host is built from them.
#[derive(Clone, Copy)]
struct Shared<'a> {
    client: &'a Arc<Mutex<Client>>,
    wasm_path: &'a Arc<PathBuf>,
    config: &'a Arc<LineageConfig>,
    invoker: &'a Arc<dyn LambdaInvoker>,
}

/// The journal connection, the compiled domain module, the lineage it runs under, and the
/// invoker that delivers a policy's cross-domain reactions. Borrowed from the server's state (or
/// a test's fixtures) for the length of one call, so it is `Copy`.
#[derive(Clone, Copy)]
pub struct Host<'a> {
    /// The one Postgres connection; its mutex serializes every write onto it.
    pub client: &'a Mutex<Client>,
    pub wasm_path: &'a Path,
    pub config: &'a LineageConfig,
    pub invoker: &'a dyn LambdaInvoker,
    shared: Option<Shared<'a>>,
}

impl<'a> Host<'a> {
    /// A host over borrowed pieces. It cannot outlive the call, so work that must outlast the
    /// response stays inline.
    pub fn new(
        client: &'a Mutex<Client>,
        wasm_path: &'a Path,
        config: &'a LineageConfig,
        invoker: &'a dyn LambdaInvoker,
    ) -> Self {
        Self {
            client,
            wasm_path,
            config,
            invoker,
            shared: None,
        }
    }

    /// A host over the server's own `Arc`s, from which `detach` can hand work an owned copy.
    pub fn shared(
        client: &'a Arc<Mutex<Client>>,
        wasm_path: &'a Arc<PathBuf>,
        config: &'a Arc<LineageConfig>,
        invoker: &'a Arc<dyn LambdaInvoker>,
    ) -> Self {
        Self {
            client,
            wasm_path,
            config,
            invoker: invoker.as_ref(),
            shared: Some(Shared {
                client,
                wasm_path,
                config,
                invoker,
            }),
        }
    }

    /// An owned copy for a task that outlives this request, or `None` when the host was built
    /// from borrows and so cannot be detached.
    pub fn detach(&self) -> Option<OwnedHost> {
        self.shared.map(|shared| OwnedHost {
            client: Arc::clone(shared.client),
            wasm_path: Arc::clone(shared.wasm_path),
            config: Arc::clone(shared.config),
            invoker: Arc::clone(shared.invoker),
        })
    }
}

/// A `Host` that owns its handles, for work spawned past the end of a request.
pub struct OwnedHost {
    client: Arc<Mutex<Client>>,
    wasm_path: Arc<PathBuf>,
    config: Arc<LineageConfig>,
    invoker: Arc<dyn LambdaInvoker>,
}

impl OwnedHost {
    pub fn host(&self) -> Host<'_> {
        Host::new(
            &self.client,
            &self.wasm_path,
            &self.config,
            self.invoker.as_ref(),
        )
    }
}
