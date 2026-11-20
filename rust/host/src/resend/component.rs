//! The Resend delivery run by the Wasm component built from `rust/adapters/resend`, for a deploy
//! whose hecksagon wires it to the `email` port (`mailed_by "Resend"`). The IR carries the module
//! by its digest and the grant the adapter declared; the host keeps the key and the network and
//! answers only what that grant names.

use super::{Account, Delivery, Email};
use crate::grants::Grants;
use rust_host_core::component_email::{self, Message, Sender};
use rust_host_core::component_imports::Imports;
use rust_host_core::components;
use serde_json::Value;
use std::path::PathBuf;
use std::sync::Arc;

/// The port a component answers to deliver email.
const PORT: &str = "email";

/// A wired component: the module the runner loads and the grant its imports are answered by.
#[derive(Clone)]
pub struct Wiring {
    pub(super) module: PathBuf,
    pub(super) grant: Arc<dyn Imports>,
}

impl Wiring {
    /// The grant as the IR declares it, copied: the secret names and the hosts, nothing more.
    fn granted(wired: components::Wired) -> Self {
        Self {
            module: wired.module,
            grant: Arc::new(Grants::new(wired.secrets, wired.hosts)),
        }
    }
}

/// The component `domain_ir` wires to the `email` port: `Ok(None)` when it wires none, so mail
/// goes out natively as before, and `Err` when it names one the host cannot load.
pub(super) fn wired(domain_ir: Option<&Value>) -> Result<Option<Wiring>, String> {
    components::wired(domain_ir, PORT)
        .transpose()
        .map(|wired| wired.map(Wiring::granted))
}

/// Hands `email` to the component on a thread of its own, so its host calls (the request, the
/// wait between retries) block that thread and never an async worker. Not `spawn_blocking`: a
/// blocking task still carries a task id, and `Grants` refuses to block inside any task. A run
/// that fails outright (no component, a trap, a passed cap) is a failed delivery naming why.
pub(super) async fn deliver(account: &Account, wiring: &Wiring, email: &Email<'_>) -> Delivery {
    deliver_as(wiring, sender(account), email).await
}

/// `deliver` with the sender the component is handed given apart from the account, so a test can
/// ask the component to post where the grant does not reach.
pub(super) async fn deliver_as(wiring: &Wiring, sender: Sender, email: &Email<'_>) -> Delivery {
    let Wiring { module, grant } = wiring.clone();
    let message = message(email);
    let (answer, answered) = tokio::sync::oneshot::channel();
    std::thread::spawn(move || {
        let _ = answer.send(component_email::deliver(&module, grant, &sender, &message));
    });
    match answered.await {
        Ok(Ok(delivery)) => Delivery {
            ok: delivery.ok,
            message_id: delivery.message_id,
            reason: delivery.reason,
        },
        Ok(Err(err)) => Delivery::failed(format!("resend component failed: {err}")),
        Err(_) => Delivery::failed("resend component failed: its thread ended without an answer"),
    }
}

pub(super) fn sender(account: &Account) -> Sender {
    Sender {
        from: account.from.clone(),
        reply_to: account.reply_to.clone(),
        base_url: account.base_url.clone(),
    }
}

fn message(email: &Email<'_>) -> Message {
    Message {
        to: email.to.to_string(),
        subject: email.subject.to_string(),
        body: email.body.to_string(),
        unsubscribe_url: email.unsubscribe_url.map(String::from),
    }
}

/// The committed component and a grant cut from a test account, so the shared cases run the
/// component against a local fake: the account's key under `RESEND_API_KEY`, and requests to the
/// account's base URL host and no other.
#[cfg(test)]
pub(super) mod committed {
    use super::{Account, Wiring};
    use crate::grants::Grants;
    use rust_host_core::component_imports::{Call, Imports, Refusal, Reply};
    use rust_host_core::module_cache;
    use sha2::{Digest, Sha256};
    use std::sync::Arc;

    /// The component as committed beside `resend.adapter`.
    pub const MODULE: &[u8] =
        include_bytes!("../../../../lib/hecks/adapters/driven/resend/resend.wasm");
    /// `resend.wasm.sha256` as committed beside it: a banner line, then `<hex>  resend.wasm`.
    const DIGEST_FILE: &str =
        include_str!("../../../../lib/hecks/adapters/driven/resend/resend.wasm.sha256");
    /// The one secret the component reads.
    const API_KEY: &str = "RESEND_API_KEY";

    struct AccountGrant {
        api_key: String,
        hosts: Grants,
    }

    impl Imports for AccountGrant {
        fn secret(&self, name: &str) -> Result<Option<String>, Refusal> {
            if name == API_KEY {
                return Ok(Some(self.api_key.clone()));
            }
            Err(Refusal::Undeclared(name.to_string()))
        }

        fn request(&self, call: Call) -> Result<Reply, Refusal> {
            self.hosts.request(call)
        }
    }

    /// The committed component, granted `account`'s key and its base URL's host.
    #[allow(clippy::expect_used)] // reason: a test fixture; the digest is checked by its own test
    pub fn wiring(account: &Account) -> Wiring {
        let encoded = base64_of(MODULE);
        let module =
            module_cache::cached("Resend", &digest(), &encoded).expect("committed resend.wasm");
        let grant = AccountGrant {
            api_key: account.api_key.clone(),
            hosts: Grants::new(Vec::<String>::new(), host_of(&account.base_url)),
        };
        Wiring {
            module,
            grant: Arc::new(grant),
        }
    }

    /// The digest `resend.wasm.sha256` records.
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

    fn host_of(base_url: &str) -> Vec<String> {
        reqwest::Url::parse(base_url)
            .ok()
            .and_then(|url| url.host_str().map(String::from))
            .into_iter()
            .collect()
    }
}
