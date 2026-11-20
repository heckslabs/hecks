//! The calls this host makes to a business's own Stripe account: read the account, create and
//! delete its webhook endpoint, open an embedded checkout session. They are answered natively
//! (`native`) or by the Stripe Wasm component (`component`), which hold the same request shapes
//! and the same mapping of Stripe's answers, and are held to one shared case list (`tests`).
//! Which key a call uses, who may ask for it and what a refusal leads to stay with the caller.

mod component;
mod native;

use serde_json::Value;
use std::sync::OnceLock;

pub use rust_host_core::component_payments::{
    AccountRefusal, EmbeddedSession, Endpoint, SessionRequest, WebhookRefusal, WebhookRequest,
};

/// Where Stripe is reached. A component's grant must name this host.
pub const API_BASE: &str = "https://api.stripe.com";

/// The account one call is made as: Stripe's base URL (the host's own setting, never a tenant's
/// input), the key the host chose for this call, and the API version to pin when the call pins
/// one. Deliberately not `Debug`: it holds a secret key.
pub struct Account<'a> {
    pub base_url: &'a str,
    pub api_key: &'a str,
    pub api_version: Option<&'a str>,
}

/// How the Stripe calls leave the host: natively, or through the Stripe Wasm component.
#[derive(Clone)]
pub enum Stripe {
    Native,
    /// The same calls run by `rust/adapters/stripe` as a component, for a deploy whose hecksagon
    /// wires it to the `payments` port: the IR's `components` names its module and grant.
    Component(component::Wiring),
}

impl Stripe {
    /// The adapter `domain_ir` wires to the `payments` port: native when it wires none, and
    /// `Err` when it names a component the host cannot load or whose grant does not reach Stripe.
    pub fn wired(domain_ir: Option<&Value>) -> Result<Self, String> {
        Ok(component::wired(domain_ir)?.map_or(Self::Native, Self::Component))
    }

    /// The adapter this process's IR wires, decided once: the IR is fixed for the life of the
    /// process, and loading a component checks its module against its digest.
    pub fn configured() -> Result<Self, String> {
        static WIRED: OnceLock<Result<Stripe, String>> = OnceLock::new();
        WIRED.get_or_init(|| Self::wired(crate::ir::ir())).clone()
    }

    /// The committed Stripe component, granted requests to `base_url`'s host and no other.
    #[cfg(test)]
    pub fn committed(base_url: &str) -> Self {
        Self::Component(component::committed::wiring(base_url))
    }

    /// The business's name as Stripe has it, `None` when it has none.
    pub async fn read_account(
        &self,
        account: &Account<'_>,
    ) -> Result<Option<String>, AccountRefusal> {
        match self {
            Self::Native => native::read_account(account).await,
            Self::Component(wiring) => component::read_account(wiring, account).await,
        }
    }

    /// Creates the webhook endpoint `wanted` describes and answers its id and signing secret.
    /// Stripe shows the signing secret only in this answer.
    pub async fn create_webhook(
        &self,
        account: &Account<'_>,
        wanted: WebhookRequest,
    ) -> Result<Endpoint, WebhookRefusal> {
        match self {
            Self::Native => native::create_webhook(account, &wanted).await,
            Self::Component(wiring) => component::create_webhook(wiring, account, wanted).await,
        }
    }

    /// Whether Stripe confirmed it removed the endpoint `endpoint_id`.
    pub async fn delete_webhook(&self, account: &Account<'_>, endpoint_id: &str) -> bool {
        match self {
            Self::Native => native::delete_webhook(account, endpoint_id).await,
            Self::Component(wiring) => {
                component::delete_webhook(wiring, account, endpoint_id).await
            }
        }
    }

    /// Opens the embedded checkout session `wanted` describes. An error carries Stripe's message
    /// when it refuses, never a key or the reply body.
    pub async fn create_checkout_session(
        &self,
        account: &Account<'_>,
        wanted: SessionRequest,
    ) -> anyhow::Result<EmbeddedSession> {
        match self {
            Self::Native => native::create_checkout_session(account, &wanted).await,
            Self::Component(wiring) => {
                component::create_checkout_session(wiring, account, wanted).await
            }
        }
    }
}

#[cfg(test)]
mod tests;
