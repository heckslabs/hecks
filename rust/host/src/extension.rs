//! The seam a host extension plugs into: extra routes, a boot check and boot-time secrets, added by
//! a crate that depends on this library instead of living in it. Commerce (payments, checkout,
//! newsletter, registrations, mail) is the first extension; `default_extensions` names what the
//! `bootstrap` binary installs when nothing else was.

use crate::ir::ir;
use crate::journal::LineageConfig;
use crate::lambda_client::LambdaInvoker;
use crate::secrets::AwsSecretFetcher;
use async_trait::async_trait;
use serde_json::Value;
use std::collections::HashMap;
use std::path::Path;
use std::sync::{Arc, OnceLock};
use tokio::sync::Mutex;
use tokio_postgres::Client;

/// One request, as an extension sees it. `domain_ir` is `None` in the guest phase when this
/// process has no IR loaded; `event` is the raw Function-URL event (guest phase only) for headers an extension needs.
pub struct Ctx<'a> {
    pub event: Option<&'a Value>,
    pub method: &'a str,
    pub path: &'a str,
    pub query: &'a HashMap<String, String>,
    pub raw_body: &'a str,
    pub cookies: &'a HashMap<String, String>,
    pub domain_ir: Option<&'a Value>,
    pub client: &'a Mutex<Client>,
    pub wasm_path: &'a Path,
    pub config: &'a LineageConfig,
    pub invoker: &'a dyn LambdaInvoker,
}

#[async_trait]
pub trait HostExtension: Send + Sync {
    /// Answers a request before the account gate: public forms, webhooks. `None` falls through.
    async fn guest_route(&self, _ctx: &Ctx<'_>) -> Option<Value> {
        None
    }

    /// Answers a request after the host's own sign-in routes, with the signed-in cookies and the
    /// domain IR in hand (`ctx.domain_ir` is always `Some`). `None` falls through.
    async fn account_route(&self, _ctx: &Ctx<'_>) -> Option<Value> {
        None
    }

    /// Refuses the boot before the database is touched, for a domain the extension cannot serve.
    fn boot_check(&self, _domain: &str) -> Result<(), String> {
        Ok(())
    }

    /// Reads the secrets the extension needs into the environment, at cold start.
    async fn boot_secrets(&self, _fetcher: &AwsSecretFetcher) {}
}

static INSTALLED: OnceLock<Vec<Arc<dyn HostExtension>>> = OnceLock::new();

/// Installs the extensions for this process; the first call wins, and it must run before any request.
pub fn install(extensions: Vec<Arc<dyn HostExtension>>) {
    let _ = INSTALLED.set(extensions);
}

/// The installed extensions, or `default_extensions` when none were installed.
pub fn installed() -> &'static [Arc<dyn HostExtension>] {
    INSTALLED.get_or_init(default_extensions)
}

fn default_extensions() -> Vec<Arc<dyn HostExtension>> {
    vec![Arc::new(crate::web::Commerce)]
}

/// The loaded domain IR, for an extension that needs it in the guest phase.
pub fn loaded_ir() -> Option<&'static Value> {
    ir()
}
