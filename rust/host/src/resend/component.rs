//! The Resend delivery run by the Wasm component built from `rust/adapters/resend`. The host keeps
//! the key and the network: the component's grant is the one key it reads and the one host it
//! posts to, answered here.

use super::{Account, Delivery, Email};
use crate::grants::Grants;
use rust_host_core::component_email::{self, Message, Sender};
use rust_host_core::component_imports::{Call, Imports, Refusal, Reply};
use sha2::{Digest, Sha256};
use std::path::PathBuf;
use std::sync::{Arc, OnceLock};

/// The component, embedded so a deploy carries exactly the build its digest names.
const MODULE: &[u8] = include_bytes!("../../../adapters/resend/resend.wasm");
/// `resend.wasm.sha256` as committed beside it: a banner line, then `<hex>  resend.wasm`.
const DIGEST_FILE: &str = include_str!("../../../adapters/resend/resend.wasm.sha256");
/// The one secret the component reads.
const API_KEY: &str = "RESEND_API_KEY";

/// What the component may reach: its account's key under `RESEND_API_KEY`, and requests to the
/// account's base URL host and no other.
struct ResendGrant {
    api_key: String,
    hosts: Grants,
}

impl Imports for ResendGrant {
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

/// Hands `email` to the component on a thread of its own, so its host calls (the request, the
/// wait between retries) block that thread and never an async worker. Not `spawn_blocking`: a
/// blocking task still carries a task id, and `Grants` refuses to block inside any task. A run
/// that fails outright (no component, a trap, a passed cap) is a failed delivery naming why.
pub(super) async fn deliver(account: &Account, email: &Email<'_>) -> Delivery {
    deliver_as(account, sender(account), email).await
}

/// `deliver` with the sender the component is handed given apart from the account its grant is
/// cut from, so a test can ask the component to post where the grant does not reach.
pub(super) async fn deliver_as(account: &Account, sender: Sender, email: &Email<'_>) -> Delivery {
    let grant = Arc::new(ResendGrant {
        api_key: account.api_key.clone(),
        hosts: Grants::new(Vec::<String>::new(), host_of(&account.base_url)),
    });
    let message = message(email);
    let (answer, answered) = tokio::sync::oneshot::channel();
    std::thread::spawn(move || {
        let ran = module_path()
            .map_err(anyhow::Error::msg)
            .and_then(|path| component_email::deliver(&path, grant, &sender, &message));
        let _ = answer.send(ran);
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

fn host_of(base_url: &str) -> Vec<String> {
    reqwest::Url::parse(base_url)
        .ok()
        .and_then(|url| url.host_str().map(String::from))
        .into_iter()
        .collect()
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

/// The digest `resend.wasm.sha256` records.
pub(super) fn committed_digest() -> &'static str {
    DIGEST_FILE
        .lines()
        .find(|line| !line.starts_with('#') && !line.trim().is_empty())
        .and_then(|line| line.split_whitespace().next())
        .unwrap_or_default()
}

/// The digest of the embedded component.
pub(super) fn embedded_digest() -> String {
    use std::fmt::Write as _;
    Sha256::digest(MODULE)
        .iter()
        .fold(String::new(), |mut out, byte| {
            let _ = write!(out, "{byte:02x}");
            out
        })
}

/// The embedded component written once to a file named by its digest, after checking the digest
/// is the committed one; the runner compiles that path once per process.
fn module_path() -> Result<PathBuf, String> {
    static PATH: OnceLock<Result<PathBuf, String>> = OnceLock::new();
    PATH.get_or_init(write_module).clone()
}

fn write_module() -> Result<PathBuf, String> {
    let digest = embedded_digest();
    if digest != committed_digest() {
        return Err("the embedded resend.wasm does not match resend.wasm.sha256".to_string());
    }
    let dir = std::env::temp_dir().join("hecks-components");
    let path = dir.join(format!("{digest}.wasm"));
    if path.exists() {
        return Ok(path);
    }
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    // Written beside and renamed, so a concurrent process never compiles a partial file.
    let partial = path.with_extension(format!("{}.partial", std::process::id()));
    std::fs::write(&partial, MODULE).map_err(|e| e.to_string())?;
    std::fs::rename(&partial, &path).map_err(|e| e.to_string())?;
    Ok(path)
}
