//! What a request handler needs to reach the domain, travelling as one value.

use crate::journal::LineageConfig;
use crate::lambda_client::LambdaInvoker;
use std::path::Path;
use tokio::sync::Mutex;
use tokio_postgres::Client;

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
}

impl<'a> Host<'a> {
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
        }
    }
}
