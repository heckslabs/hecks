//! The Stripe calls run by the Wasm component built from `rust/adapters/stripe`, for a deploy
//! whose hecksagon wires it to the `payments` port (`charged_by "Stripe"`). The IR carries the
//! module by its digest and the hosts the adapter declared; the host keeps every key and hands
//! each call the one it chose, so the component is granted requests and no secret.

use super::{
    Account, AccountRefusal, EmbeddedSession, Endpoint, SessionRequest, WebhookRefusal,
    WebhookRequest,
};
use crate::grants::Grants;
use rust_host_core::component_payments::{self as binding, Adapter, PAYMENTS_LIMITS};
use rust_host_core::components;
use serde_json::Value;
use std::sync::Arc;

/// The port a component answers to make the Stripe calls.
const PORT: &str = "payments";

/// A wired component: the module the runner loads, the grant its requests are answered by, and
/// what one call may spend.
#[derive(Clone)]
pub struct Wiring {
    pub(super) adapter: Adapter,
}

impl Wiring {
    /// The grant as the IR declares it: its hosts, and no secret whatever it lists. Refused when
    /// those hosts do not name where Stripe is reached, since every call would then fail quietly.
    fn granted(wired: components::Wired) -> Result<Self, String> {
        let stripe = host_of(super::API_BASE);
        if !wired
            .hosts
            .iter()
            .any(|host| host.eq_ignore_ascii_case(&stripe))
        {
            return Err(format!(
                "{}'s grant does not name {stripe}, where Stripe is reached",
                wired.adapter
            ));
        }
        Ok(Self {
            adapter: Adapter {
                module: wired.module,
                imports: Arc::new(Grants::new(Vec::<String>::new(), wired.hosts)),
                limits: PAYMENTS_LIMITS,
            },
        })
    }
}

fn host_of(base_url: &str) -> String {
    reqwest::Url::parse(base_url)
        .ok()
        .and_then(|url| url.host_str().map(String::from))
        .unwrap_or_default()
}

/// The component `domain_ir` wires to the `payments` port: `Ok(None)` when it wires none, so the
/// calls are made natively as before, and `Err` when it names one the host cannot use.
pub(super) fn wired(domain_ir: Option<&Value>) -> Result<Option<Wiring>, String> {
    components::wired(domain_ir, PORT)
        .transpose()?
        .map(Wiring::granted)
        .transpose()
}

/// Runs `call` against the component on a thread of its own, so its request blocks that thread
/// and never an async worker. Not `spawn_blocking`: a blocking task still carries a task id, and
/// `Grants` refuses to block inside any task. An `Err` is the run's own failure (no component, a
/// trap, a passed cap); it names the cap or the trap and never an argument of the call.
async fn run<T: Send + 'static>(
    wiring: &Wiring,
    call: impl FnOnce(&Adapter) -> anyhow::Result<T> + Send + 'static,
) -> anyhow::Result<T> {
    let adapter = wiring.adapter.clone();
    let (answer, answered) = tokio::sync::oneshot::channel();
    std::thread::spawn(move || {
        let _ = answer.send(call(&adapter));
    });
    answered
        .await
        .unwrap_or_else(|_| Err(anyhow::anyhow!("its thread ended without an answer")))
}

fn handed(account: &Account<'_>) -> binding::Account {
    binding::Account {
        base_url: account.base_url.to_string(),
        api_key: account.api_key.to_string(),
        api_version: account.api_version.map(String::from),
    }
}

fn failed(err: &anyhow::Error) {
    eprintln!("stripe component failed: {err}");
}

/// A run that fails outright is Stripe not reached.
pub(super) async fn read_account(
    wiring: &Wiring,
    account: &Account<'_>,
) -> Result<Option<String>, AccountRefusal> {
    let account = handed(account);
    run(wiring, move |adapter| adapter.read_account(&account))
        .await
        .unwrap_or_else(|err| {
            failed(&err);
            Err(AccountRefusal::Unreachable)
        })
}

/// A run that fails outright is a webhook that was not created.
pub(super) async fn create_webhook(
    wiring: &Wiring,
    account: &Account<'_>,
    wanted: WebhookRequest,
) -> Result<Endpoint, WebhookRefusal> {
    let account = handed(account);
    run(wiring, move |adapter| {
        adapter.create_webhook(&account, &wanted)
    })
    .await
    .unwrap_or_else(|err| {
        failed(&err);
        Err(WebhookRefusal::Other)
    })
}

/// A run that fails outright is a removal Stripe did not confirm.
pub(super) async fn delete_webhook(
    wiring: &Wiring,
    account: &Account<'_>,
    endpoint_id: &str,
) -> bool {
    let (account, endpoint_id) = (handed(account), endpoint_id.to_string());
    run(wiring, move |adapter| {
        adapter.delete_webhook(&account, &endpoint_id)
    })
    .await
    .unwrap_or_else(|err| {
        failed(&err);
        false
    })
}

/// A run that fails outright is an error naming the run's failure.
pub(super) async fn create_checkout_session(
    wiring: &Wiring,
    account: &Account<'_>,
    wanted: SessionRequest,
) -> anyhow::Result<EmbeddedSession> {
    let account = handed(account);
    run(wiring, move |adapter| {
        adapter.create_checkout_session(&account, &wanted)
    })
    .await
    .map_err(|err| anyhow::anyhow!("stripe component failed: {err}"))?
    .map_err(anyhow::Error::msg)
}

/// The committed component and a grant cut for a test: requests to one base URL's host only.
#[cfg(test)]
pub(super) mod committed {
    use super::{host_of, Adapter, Wiring, PAYMENTS_LIMITS};
    use crate::grants::Grants;
    use rust_host_core::module_cache;
    use sha2::{Digest, Sha256};
    use std::sync::Arc;

    /// The component as committed beside `stripe.adapter`.
    pub const MODULE: &[u8] =
        include_bytes!("../../../../../lib/hecks/adapters/driven/stripe/stripe.wasm");
    /// `stripe.wasm.sha256` as committed beside it: a banner line, then `<hex>  stripe.wasm`.
    const DIGEST_FILE: &str =
        include_str!("../../../../../lib/hecks/adapters/driven/stripe/stripe.wasm.sha256");

    /// The committed component, granted requests to `base_url`'s host.
    #[allow(clippy::expect_used)] // reason: a test fixture; the digest is checked by its own test
    pub fn wiring(base_url: &str) -> Wiring {
        let module = module_cache::cached("Stripe", &digest(), &base64_of(MODULE))
            .expect("committed stripe.wasm");
        Wiring {
            adapter: Adapter {
                module,
                imports: Arc::new(Grants::new(Vec::<String>::new(), vec![host_of(base_url)])),
                limits: PAYMENTS_LIMITS,
            },
        }
    }

    /// The digest `stripe.wasm.sha256` records.
    pub fn committed_digest() -> &'static str {
        DIGEST_FILE
            .lines()
            .find(|line| !line.starts_with('#') && !line.trim().is_empty())
            .and_then(|line| line.split_whitespace().next())
            .unwrap_or_default()
    }

    /// The digest of the committed module's bytes.
    pub fn digest() -> String {
        module_cache::hex(&Sha256::digest(MODULE))
    }

    pub fn base64_of(bytes: &[u8]) -> String {
        use base64::Engine as _;
        base64::engine::general_purpose::STANDARD.encode(bytes)
    }
}
