// Commerce as a host extension: the newsletter, payments, registrations and mail routes, their boot
// check and their boot-time secret, answered through `extension::HostExtension` instead of being
// named in `render` and `route`.

use super::{
    checkout_enabled, newsletter, newsletter_send, payments_routes, registrations_list_route, resend_webhook, respond, session_secret,
};
use crate::extension::{Ctx, HostExtension, RateRule};
use crate::payments;
use crate::secrets::{self, AwsSecretFetcher};
use async_trait::async_trait;
use serde_json::Value;

pub struct Commerce;

fn checkout_domain() -> Option<String> {
    std::env::var("HECKS_CHECKOUT_DOMAIN").ok()
}

#[async_trait]
impl HostExtension for Commerce {
    // Registration/checkout/newsletter routes are opt-in: they only exist when HECKS_CHECKOUT_DOMAIN
    // names this domain, since Event/Registration and the Payments::Payment chapter are declared
    // against it specifically. The capability shapes are pinned by
    // spec/fixtures/rust_host/checkout_fixture, which this module's tests run against.
    async fn guest_route(&self, ctx: &Ctx<'_>) -> Option<Value> {
        if !checkout_enabled(checkout_domain().as_deref(), &ctx.config.domain) {
            return None;
        }
        let ir = crate::extension::loaded_ir();
        // Newsletter subscribe shares this gate (same hecksagon as the registration aggregates) and
        // is checked first since it needs none of the Payments::Payment/Event context checkout
        // requires. The subscriber list is PII (email, names, status): only an Admin or Owner
        // holding the account cookie may read it, like sending does.
        if ctx.method == "GET" && ctx.path == "/newsletter/subscribers" && ir.and_then(crate::commerce_ir::newsletter_provider).is_some() {
            let Some(domain_ir) = ir else {
                return Some(respond(500, "text/plain", "HECKS_IR_PATH not set or unreadable — this domain has no web layer configured"));
            };
            if let Err(response) = newsletter_send::require_admin(domain_ir, ctx.cookies, &session_secret(), ctx.client).await {
                return Some(response);
            }
        }
        let headers = ctx.event.and_then(|e| e.get("headers"));
        if let Some(response) =
            resend_webhook::resend_webhook_route(ctx.method, ctx.path, ctx.raw_body, headers, ctx.client, ctx.wasm_path, ctx.config, ctx.invoker).await
        {
            return Some(response);
        }
        if let Some(response) =
            newsletter::newsletter_route(ctx.method, ctx.path, ctx.query, ctx.raw_body, ctx.client, ctx.wasm_path, ctx.config, ctx.invoker).await
        {
            return Some(response);
        }
        let stripe_signature = ctx
            .event
            .and_then(|e| e.get("headers"))
            .and_then(|h| h.get("stripe-signature"))
            .and_then(|v| v.as_str())
            .unwrap_or("");
        payments_routes(ir, ctx.method, ctx.path, ctx.raw_body, stripe_signature, ctx.client, ctx.wasm_path, ctx.config, ctx.invoker).await
    }

    async fn account_route(&self, ctx: &Ctx<'_>) -> Option<Value> {
        let domain_ir = ctx.domain_ir?;
        let secret = session_secret();
        // Sending a newsletter issue (web/newsletter_send.rs's own header): an Admin's or Owner's
        // account cookie, unlike the guest newsletter routes served ahead of the account gate.
        if newsletter_send::issue_action(ctx.method, ctx.path).is_some() {
            return newsletter_send::issue_route(
                ctx.method, ctx.path, domain_ir, ctx.raw_body, ctx.cookies, &secret, ctx.client, ctx.wasm_path, ctx.config, ctx.invoker,
            )
            .await;
        }
        if ctx.method == "GET" && ctx.path == "/registrations" {
            return Some(registrations_list_route(domain_ir, ctx.cookies, &secret, ctx.client, ctx.wasm_path, ctx.config).await);
        }
        // The tenant's payment connection: same gate as the checkout routes, since only the
        // HECKS_CHECKOUT_DOMAIN domain carries one — any other domain served by this binary falls
        // through as unknown.
        if payments::owns(ctx.method, ctx.path) && checkout_enabled(checkout_domain().as_deref(), &ctx.config.domain) {
            return payments::route(
                ctx.method, ctx.path, ctx.raw_body, ctx.cookies, &secret, domain_ir, &payments::PlatformConfig::load().await,
                ctx.client, ctx.wasm_path, ctx.config, ctx.invoker,
            )
            .await;
        }
        None
    }

    fn rate_rules(&self) -> Vec<RateRule> {
        vec![
            RateRule { name: "subscribe", method: "POST", path: "/newsletter/subscribers", limit_env: "HECKS_RATE_LIMIT_SUBSCRIBE", default_limit: 10 },
            RateRule { name: "register", method: "POST", path: "/registrations", limit_env: "HECKS_RATE_LIMIT_REGISTER", default_limit: 15 },
        ]
    }

    // Checkout on AWS keeps the business's payment keys in a named Secrets Manager secret; refuse
    // before touching the database when none is named.
    fn boot_check(&self, domain: &str) -> Result<(), String> {
        payments::check_boot(checkout_enabled(checkout_domain().as_deref(), domain))
    }

    // RESEND_SECRET_ID: a failed fetch only logs -- mail is optional, and a missing secret must not
    // stop the host from serving everything else (resend.rs answers 503 without a key). The same
    // secret may also carry `webhook_secret`, the signing secret of the Resend webhook that
    // POST /webhooks/resend verifies; without it that route answers 503.
    async fn boot_secrets(&self, fetcher: &AwsSecretFetcher) {
        let Ok(resend_secret_id) = std::env::var("RESEND_SECRET_ID") else { return };
        let fetched = fetcher.fetch_secret_string(&resend_secret_id).await.map_err(|e| format!("{e:#}"));
        let read = fetched.and_then(|json| secrets::extract_field(&json, "api_key").map(|api_key| (api_key, secrets::optional_field(&json, "webhook_secret"))));
        match read {
            Ok((api_key, webhook_secret)) => unsafe {
                std::env::set_var("RESEND_API_KEY", api_key);
                if let Some(webhook_secret) = webhook_secret {
                    std::env::set_var("RESEND_WEBHOOK_SECRET", webhook_secret);
                }
            },
            Err(e) => eprintln!("RESEND_SECRET_ID could not be read, so email sending stays off: {e}"),
        }
    }
}
