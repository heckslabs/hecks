// Calls a payments adapter compiled to a component (world `payments-adapter` in `rust/host/wit`):
// read the account, create and delete its webhook endpoint, open an embedded checkout session.
// The component reaches the processor only through the `http-out` the caller's `Imports` grants,
// and is handed the key of each call; this file holds the binding and the limits of one call.

use crate::component_imports::Imports;
use crate::component_runner::run_with;
use crate::wasm_runner::Limits;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

mod wit {
    wasmtime::component::bindgen!({
        path: "../wit",
        world: "payments-adapter",
        with: {
            "hecks:adapters/http-out": crate::component_imports::wit::hecks::adapters::http_out,
        },
    });
}

pub use wit::hecks::adapters::stripe::{
    Account, AccountRefusal, EmbeddedSession, Endpoint, SessionRequest, WebhookRefusal,
    WebhookRequest,
};

/// What one call may spend. The deadline counts wall time, host calls included, so it covers the
/// one request a call makes at its 15 s timeout, with room to spare. Memory and output are a
/// form body's and a JSON answer's worth.
pub const PAYMENTS_LIMITS: Limits = Limits {
    deadline: Duration::from_secs(20),
    memory_bytes: 16 * 1024 * 1024,
    output_bytes: 64 * 1024,
};

/// A payments component ready to be called: its module, what answers its imports, and what one
/// call may spend.
#[derive(Clone)]
pub struct Adapter {
    pub module: PathBuf,
    pub imports: Arc<dyn Imports>,
    pub limits: Limits,
}

impl Adapter {
    /// The business's name as the processor has it. An outer `Err` is the run's own failure (no
    /// such component, a trap, a passed cap); the processor's refusal is the inner one.
    pub fn read_account(
        &self,
        account: &Account,
    ) -> anyhow::Result<Result<Option<String>, AccountRefusal>> {
        self.run(|store, adapter| Ok(adapter.call_read_account(store, account)?))
    }

    /// Creates the webhook endpoint `wanted` describes in `account`.
    pub fn create_webhook(
        &self,
        account: &Account,
        wanted: &WebhookRequest,
    ) -> anyhow::Result<Result<Endpoint, WebhookRefusal>> {
        self.run(|store, adapter| Ok(adapter.call_create_webhook(store, account, wanted)?))
    }

    /// Whether the processor confirmed it removed the endpoint `endpoint_id`.
    pub fn delete_webhook(&self, account: &Account, endpoint_id: &str) -> anyhow::Result<bool> {
        self.run(|store, adapter| Ok(adapter.call_delete_webhook(store, account, endpoint_id)?))
    }

    /// Opens the embedded checkout session `wanted` describes; the inner `Err` is the
    /// processor's own reason.
    pub fn create_checkout_session(
        &self,
        account: &Account,
        wanted: &SessionRequest,
    ) -> anyhow::Result<Result<EmbeddedSession, String>> {
        self.run(|store, adapter| Ok(adapter.call_create_checkout_session(store, account, wanted)?))
    }

    fn run<T>(
        &self,
        call: impl FnOnce(
            &mut wasmtime::Store<crate::component_runner::RunState>,
            &wit::PaymentsAdapter,
        ) -> anyhow::Result<T>,
    ) -> anyhow::Result<T> {
        run_with(
            self.limits,
            &self.module,
            self.imports.clone(),
            |store, instance| {
                let adapter = wit::PaymentsAdapter::new(&mut *store, instance)?;
                call(store, &adapter)
            },
        )
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used)]

    use super::*;
    use crate::component_imports::NoGrants;
    use crate::module_cache;
    use base64::Engine as _;
    use sha2::{Digest, Sha256};

    const MODULE: &[u8] =
        include_bytes!("../../../../lib/hecks/adapters/driven/stripe/stripe.wasm");

    /// The committed component with nothing granted.
    fn ungranted() -> Adapter {
        let digest = module_cache::hex(&Sha256::digest(MODULE));
        let encoded = base64::engine::general_purpose::STANDARD.encode(MODULE);
        Adapter {
            module: module_cache::cached("Stripe", &digest, &encoded).unwrap(),
            imports: Arc::new(NoGrants),
            limits: PAYMENTS_LIMITS,
        }
    }

    fn account() -> Account {
        Account {
            base_url: "https://api.stripe.com".to_string(),
            api_key: "rk_test_BINDING_KEY".to_string(),
            api_version: None,
        }
    }

    #[test]
    fn a_component_granted_nothing_answers_every_call_as_stripe_not_reached() {
        let adapter = ungranted();
        assert!(matches!(
            adapter.read_account(&account()).unwrap(),
            Err(AccountRefusal::Unreachable)
        ));
        assert!(!adapter.delete_webhook(&account(), "we_1").unwrap());
    }

    #[test]
    fn a_refused_session_names_what_was_not_granted_and_never_the_key() {
        let wanted = SessionRequest {
            price_cents: 100,
            currency: "usd".to_string(),
            product_name: "Class".to_string(),
            registration_id: "REG-1".to_string(),
            expires_at: 1,
        };
        let refused = ungranted()
            .create_checkout_session(&account(), &wanted)
            .unwrap()
            .unwrap_err();
        assert_eq!(
            refused,
            "Stripe unreachable: https://api.stripe.com/v1/checkout/sessions is not granted"
        );
    }
}
