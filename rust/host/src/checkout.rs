// LifeAdelics' checkout/webhook boundary — the two mechanics
// adapters/http_server.rb (Ruby, lifeadelics repo) hand-rolls against
// the `stripe` gem: opening a real Stripe Checkout Session (the outbound
// half of lifeadelics.hecksagon's own "checkout" port,
// Registration.opened_by) and verifying a Stripe webhook's own
// HMAC-SHA256 signature scheme (the inbound half, driving Payment's
// PaymentGateway port). Both hand-written here, not IR-driven —
// `rust/project/ports.rb`'s own `emit_port_operation` covers only
// inbound port operations (PaymentGateway.Succeeded/Failed, dispatched
// from web.rs's own checkout_route through the already-proven
// port-operation + policy-reaction codegen path); no domain in this
// corpus has an outbound driving port or a webhook-shaped signature
// scheme to generalize this against yet, so it stays a real, scoped
// specialization (web.rs's own "LIFEADELICS-specific glue" header has
// the fuller reasoning) rather than a new IR capability invented
// speculatively for a population of one.
//
// Equivalence-gap plan 3.3 — considered, declined, checked directly
// against this checkout rather than assumed: population here is
// actually zero reachable examples, not one. There is no Lifeadelics
// `.bluebook`/`.hecksagon` source anywhere in this checkout to design a
// second `signature_scheme`/`opens_external_call` DSL word against —
// deploy/lifeadelics{,-demo} were deleted outright (`eb3bd853`, commit
// message: "generated from ephemeral /tmp paths during tool testing,
// not the real client config... which already lives in
// ~/Projects/lifeadelics/deploy-aws"), and `rust/dist/` carries no
// `lifeadelics.{wasm,ir.json}` either — every artifact this task would
// need to validate against, gone, not merely out of reach in a private
// repo. A synthetic-only fixture would be the only thing exercising new
// IR/DSL surface this checkout could ever build, the same "invented
// generality with no real backing" reasoning process_manager.rb's own
// Saga/undoes comment already declines building compensation-ordering
// for — except that item at least had one real corpus example (Banking's
// Settlement saga) to check a design against; this has none.
//
// A separate, real blocker surfaced investigating this anyway, worth
// recording even though the feature above stays declined: the plan's
// own proposed gate ("does `domain_ir` declare an `external_gateways`
// entry") cannot work as designed for Lifeadelics regardless, because
// `web.rs`'s own header (below) states `ir()` never resolves for a
// Shared-mode domain at all — `HECKS_IR_PATH` is only emitted by
// `bin/project_deploy` when `rust_web` is true (that script's own
// `rust_web ? %(\n HECKS_IR_PATH: ...) : ""` conditional), yet
// `rust/host/src/main.rs`'s own boot sequence reads `ir::ir().ok_or(...)?`
// unconditionally, for every domain regardless of web mode — confirmed
// live against Banking's own committed `deploy/banking/template.yaml`
// (Shared/`AuthType: AWS_IAM`, confirming `rust_web == false` there),
// which genuinely carries no `HECKS_IR_PATH` key at all. That is a real,
// separate, currently-live contradiction between `main.rs` and
// `bin/project_deploy` — unrelated to Lifeadelics specifically, not
// fixed here (a different subsystem, a different task), but flagged
// plainly rather than silently discovered and dropped.
//
// Equivalence-gap plan 3.4 (orphaned `Payments::Payment` sweep) —
// also considered, also declined, checked against this same absence
// rather than assumed compatible with it. The detection half is
// genuinely buildable correctly: `registrations_route`'s own
// `Payment.Initiate`/`Registration.Request` calls (below) already
// prove `reference` and `registration_id` are the same string, so "a
// Payment whose reference has no matching Registration" is a real,
// answerable query via `instances_for` against both prefixes, no
// guessing required. The action half is not: the plan's own text
// already names the reason ("confirm the exact command name once
// domain source is available, or coordinate with whoever owns the
// private Lifeadelics repo") — this checkout has no way to know
// whether `Payments::Payment` even declares a command for
// flagging/expiring a record, let alone its name or payload shape,
// since (as above) no `.bluebook` source for it exists here at all.
// The routes that do exist are now verified here against
// spec/fixtures/rust_host/checkout_fixture (a trimmed copy of the
// Event/Registration/Payment shape, built to
// rust/dist/checkout_fixture.wasm), but that fixture only pins what
// these routes already dispatch; it can't answer what the real
// Payments package names a flag/expire command. The admin-route
// stopgap stays follow-up work for the repo holding that source.
//
// **Mock by default, real stripe opt-in** — mirrors the Ruby app's own
// choice exactly (MockStripeAdapter unconditionally in every
// environment except a real deploy — bin/smoke_test's own header: "the
// same as every environment except a real deploy"), not a scaled-down
// version of it. payments.rs's own `checkout_plan` decides which side of
// the line a request is on, from the tenant's own `PaymentConnection`:
// anything short of an enabled Stripe connection means
// `mock_checkout_session` below, never a real network call;
// `STRIPE_WEBHOOK_SECRET` falls back to web.rs's fixed, publicly-known,
// non-secret `MOCK_STRIPE_WEBHOOK_SECRET` — so a mock deploy needs no
// webhook secret configured to be exercisable, registration through
// confirmation. (The Ruby app and its
// confirm_payment_manually script sign against their own fixed string,
// "whsec_mock_lifeadelics_fixed"; a deploy driven by that tooling sets
// STRIPE_WEBHOOK_SECRET to it.) Which domain these routes serve at all
// is `HECKS_CHECKOUT_DOMAIN` (web.rs `render`).

use hmac::{Hmac, Mac};
use serde_json::Value;
use sha2::Sha256;

type HmacSha256 = Hmac<Sha256>;

// docs.stripe.com/webhooks#verify-events — 5 minutes, guards against a
// replayed old payload even against a leaked (not yet rotated) secret.
const TOLERANCE_SECONDS: i64 = 300;

pub struct SignatureError(pub String);

impl std::fmt::Display for SignatureError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.0)
    }
}

// Stripe's own documented scheme (docs.stripe.com/webhooks#verify-
// manually), ported from `Stripe::Webhook.construct_event` (the Ruby
// gem, called directly from adapters/http_server.rb) rather than
// reinvented: header shape "t=<unix ts>,v1=<hex hmac>[,v1=<hex
// hmac>...]" (more than one v1 during a secret-rotation window — any
// match is accepted, same as the gem), signed payload is exactly
// "<timestamp>.<raw body>", the raw bytes Stripe sent, never a
// re-serialized JSON string (re-encoding would silently disagree on
// whitespace/key order and every signature would fail to verify).
// `now` is a parameter, not read internally, so a test can hold time
// fixed rather than racing the tolerance window.
pub fn verify_signature(payload: &str, header: &str, secret: &str, now: i64) -> Result<(), SignatureError> {
    let mut timestamp: Option<i64> = None;
    let mut signatures: Vec<&str> = Vec::new();
    for part in header.split(',') {
        let Some((key, value)) = part.split_once('=') else { continue };
        match key {
            "t" => timestamp = value.parse().ok(),
            "v1" => signatures.push(value),
            _ => {}
        }
    }
    let Some(timestamp) = timestamp else {
        return Err(SignatureError("Stripe-Signature header has no t= timestamp".to_string()));
    };
    if signatures.is_empty() {
        return Err(SignatureError("Stripe-Signature header has no v1= signature".to_string()));
    }
    if (now - timestamp).abs() > TOLERANCE_SECONDS {
        return Err(SignatureError(format!(
            "timestamp {timestamp} is outside the {TOLERANCE_SECONDS}s tolerance (now: {now})"
        )));
    }

    let signed_payload = format!("{timestamp}.{payload}");
    let mut mac = HmacSha256::new_from_slice(secret.as_bytes())
        .map_err(|e| SignatureError(format!("webhook secret unusable as an HMAC key: {e}")))?;
    mac.update(signed_payload.as_bytes());
    let expected_hex = hex_encode(&mac.finalize().into_bytes());

    if signatures.iter().any(|sig| constant_time_eq(sig.as_bytes(), expected_hex.as_bytes())) {
        Ok(())
    } else {
        Err(SignatureError("signature does not match — wrong secret, or the payload was tampered with in transit".to_string()))
    }
}

fn hex_encode(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

// A timing side-channel on webhook signature comparison is a real,
// documented attack class — exactly why Stripe's own libraries compare
// this way rather than a bare `==`, which short-circuits at the first
// differing byte. Compared as the hex text the header actually carries
// (hmac's own `finalize()` gives a constant-time-comparable `CtOutput`
// for the raw bytes, but this needs the same hex round-trip either way
// to line up against `header`'s own v1= values, so it's done by hand).
fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    a.iter().zip(b.iter()).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

// **The mock outbound side** — Lifeadelics' OWN `LocalCheckout` adapter
// (adapters/local_checkout/local_checkout.rb), not hecks' generic
// MockStripeAdapter (mock_stripe_adapter.rb's `create_session`, which
// instant-skips straight to `success_url` with nothing for a guest to
// see). LocalCheckout hands back a URL to THIS SITE'S OWN
// `/pay/<registration_id>.html` page (src/pages/pay/[registrationId].astro)
// — a real page showing what's owed, with a "Pay"/"Cancel" a guest
// actually clicks, before the browser ever reaches success_url/
// cancel_url. Still entirely fake underneath: that page's "Pay" button
// calls this same host's own POST /registrations/:id/complete
// (registration_complete_route, above), which settles the Payment
// through the same PaymentGateway port /webhooks/stripe uses.
// success_url/cancel_url ride along as query params on the /pay URL
// (encoded, not interpolated raw) exactly like the Ruby adapter's own
// `URI.encode_www_form(success_url:, cancel_url:)`.
pub fn mock_checkout_session(registration_id: &str, success_url: &str, cancel_url: &str, site_url: &str) -> String {
    let mut url = reqwest::Url::parse(&format!("{site_url}/pay/{registration_id}.html"))
        .unwrap_or_else(|_| reqwest::Url::parse("http://invalid.invalid/").unwrap());
    url.query_pairs_mut().append_pair("success_url", success_url).append_pair("cancel_url", cancel_url);
    url.to_string()
}

// **The outbound side** — adapters/stripe_connect/stripe_connect.rb's own
// `create_session`, same line item the Ruby version builds: currency
// hardcoded "usd" (same as Ruby — lifeadelics' own Event::Money value object
// carries no currency at all, see lifeadelics.bluebook's own comment on it),
// one line item, quantity 1, and the same metadata key ("registration_id")
// web.rs's own webhook route reads back to recover which Payment/
// Registration this session belongs to.
//
// A direct charge on the tenant's own connected account: the platform's key
// authenticates the call and the `Stripe-Account` header names the account
// the session (and the money) belongs to, exactly `stripe_account:` in the
// Ruby adapter's request options.
//
// The session is embedded: the guest pays in a form the site mounts inline,
// never on a Stripe-hosted page, so Stripe returns a `client_secret` for the
// browser instead of a `url`. `ui_mode` is `embedded_page`; Stripe rejects the
// older `embedded` value on every API version. `redirect_on_completion=never`
// keeps the guest on the site when the payment completes, and there is no
// success_url or cancel_url because nothing leaves the site: the browser
// learns of completion from Stripe.js and the payment itself is settled by the
// webhook.

/// The Stripe API version every session request is pinned to. `embedded_page`
/// exists from this line of versions on, so the request must not depend on
/// whatever default the platform account happens to have.
pub const STRIPE_API_VERSION: &str = "2026-04-22.dahlia";

/// How one Stripe call is authenticated and addressed: the platform's own
/// secret key, the connected account the call acts on behalf of, and the API
/// base URL (`https://api.stripe.com` outside of tests).
pub struct StripeAuth<'a> {
    pub api_key: &'a str,
    pub account: Option<&'a str>,
    pub base_url: &'a str,
}

/// What the browser needs to mount an embedded Checkout Session: the session's
/// own id and the `client_secret` Stripe.js takes to render the payment form.
pub struct EmbeddedSession {
    pub session_id: String,
    pub client_secret: String,
}

/// How long an unpaid checkout keeps its seat, in seconds. Stripe accepts an
/// expiry from 30 minutes to 24 hours after the session is created, so the
/// hold is 31 minutes to stay clear of the minimum; when the session expires,
/// Stripe's `checkout.session.expired` event fails the Payment and the seat is
/// free again.
pub const SESSION_HOLD_SECONDS: i64 = 31 * 60;

/// The Unix time an embedded session created at `now` expires at.
pub fn session_expires_at(now: i64) -> i64 {
    now + SESSION_HOLD_SECONDS
}

/// Opens an embedded Checkout Session for one registration on the tenant's
/// account and returns what the browser needs to mount the payment form. The
/// session expires at `expires_at` (Unix seconds), which releases the seat an
/// abandoned checkout was holding. Errors carry Stripe's message when it
/// refuses, never a secret.
pub async fn create_checkout_session(
    auth: &StripeAuth<'_>,
    price_cents: i64,
    product_name: &str,
    registration_id: &str,
    expires_at: i64,
) -> anyhow::Result<EmbeddedSession> {
    let unit_amount = price_cents.to_string();
    let expires_at = expires_at.to_string();
    let params = [
        ("mode", "payment"),
        ("ui_mode", "embedded_page"),
        ("redirect_on_completion", "never"),
        ("expires_at", expires_at.as_str()),
        ("line_items[0][price_data][currency]", "usd"),
        ("line_items[0][price_data][unit_amount]", unit_amount.as_str()),
        ("line_items[0][price_data][product_data][name]", product_name),
        ("line_items[0][quantity]", "1"),
        ("metadata[registration_id]", registration_id),
    ];

    let mut request = reqwest::Client::new()
        .post(format!("{}/v1/checkout/sessions", auth.base_url))
        .bearer_auth(auth.api_key)
        .header("Stripe-Version", STRIPE_API_VERSION)
        .form(&params);
    if let Some(account) = auth.account {
        request = request.header("Stripe-Account", account);
    }
    let response = request.send().await?;

    let status = response.status();
    let body: Value = response.json().await?;
    if !status.is_success() {
        let message = body
            .get("error")
            .and_then(|e| e.get("message"))
            .and_then(|v| v.as_str())
            .unwrap_or("unknown Stripe error");
        anyhow::bail!("Stripe checkout session creation failed ({status}): {message}");
    }

    let text = |field: &str| body.get(field).and_then(|v| v.as_str()).map(String::from);
    match (text("id"), text("client_secret")) {
        (Some(session_id), Some(client_secret)) => Ok(EmbeddedSession { session_id, client_secret }),
        // The body is left out of the message: it may carry the client secret.
        _ => anyhow::bail!("Stripe's response carried no \"id\" and \"client_secret\" for the embedded session"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sign(secret: &str, timestamp: i64, payload: &str) -> String {
        let signed_payload = format!("{timestamp}.{payload}");
        let mut mac = HmacSha256::new_from_slice(secret.as_bytes()).unwrap();
        mac.update(signed_payload.as_bytes());
        hex_encode(&mac.finalize().into_bytes())
    }

    #[test]
    fn mock_checkout_session_matches_local_checkouts_own_pay_page_shape() {
        // local_checkout.rb's own real output, same three parts: this
        // site's own /pay/<registration_id>.html page, with success_url
        // and cancel_url riding along as encoded query params.
        let url = mock_checkout_session(
            "REG-1",
            "https://example.com/yoga.html?registered=1",
            "https://example.com/yoga.html?registered=0",
            "https://example.com",
        );
        assert_eq!(
            url,
            "https://example.com/pay/REG-1.html?success_url=https%3A%2F%2Fexample.com%2Fyoga.html%3Fregistered%3D1&cancel_url=https%3A%2F%2Fexample.com%2Fyoga.html%3Fregistered%3D0"
        );
    }

    #[test]
    fn mock_checkout_session_carries_the_registration_id_in_its_own_path_not_a_query_param() {
        let url = mock_checkout_session("REG-2", "https://example.com/yoga.html", "https://example.com/yoga.html", "https://example.com");
        assert!(url.starts_with("https://example.com/pay/REG-2.html?"));
    }

    #[test]
    fn a_correctly_signed_payload_verifies() {
        let payload = r#"{"type":"checkout.session.completed"}"#;
        let secret = "whsec_test";
        let now = 1_700_000_000;
        let header = format!("t={now},v1={}", sign(secret, now, payload));

        assert!(verify_signature(payload, &header, secret, now).is_ok());
    }

    #[test]
    fn a_payload_tampered_with_after_signing_is_rejected() {
        let secret = "whsec_test";
        let now = 1_700_000_000;
        let header = format!("t={now},v1={}", sign(secret, now, r#"{"type":"checkout.session.completed"}"#));

        // Same header, different body — exactly what an attacker
        // intercepting and rewriting the request in transit would send.
        let tampered = r#"{"type":"checkout.session.expired"}"#;
        assert!(verify_signature(tampered, &header, secret, now).is_err());
    }

    #[test]
    fn the_wrong_secret_is_rejected() {
        let payload = r#"{"type":"checkout.session.completed"}"#;
        let now = 1_700_000_000;
        let header = format!("t={now},v1={}", sign("whsec_real", now, payload));

        assert!(verify_signature(payload, &header, "whsec_wrong", now).is_err());
    }

    #[test]
    fn a_timestamp_outside_the_tolerance_window_is_rejected_even_with_a_correct_signature() {
        let payload = r#"{"type":"checkout.session.completed"}"#;
        let secret = "whsec_test";
        let signed_at = 1_700_000_000;
        let header = format!("t={signed_at},v1={}", sign(secret, signed_at, payload));

        // A replayed webhook -- the signature is genuinely correct for
        // its own timestamp, which is exactly why the tolerance check has
        // to be a separate, independent gate rather than folded into
        // "does the signature verify at all."
        let much_later = signed_at + TOLERANCE_SECONDS + 1;
        assert!(verify_signature(payload, &header, secret, much_later).is_err());
    }

    #[test]
    fn a_second_v1_during_a_secret_rotation_window_verifies_against_either() {
        let payload = r#"{"type":"checkout.session.completed"}"#;
        let old_secret = "whsec_old";
        let new_secret = "whsec_new";
        let now = 1_700_000_000;
        let header = format!(
            "t={now},v1={},v1={}",
            sign(old_secret, now, payload),
            sign(new_secret, now, payload)
        );

        assert!(verify_signature(payload, &header, old_secret, now).is_ok());
        assert!(verify_signature(payload, &header, new_secret, now).is_ok());
    }

    #[test]
    fn a_header_with_no_v1_at_all_is_rejected() {
        let now = 1_700_000_000;
        let header = format!("t={now}");
        assert!(verify_signature("{}", &header, "whsec_test", now).is_err());
    }

    #[test]
    fn a_header_with_no_timestamp_at_all_is_rejected() {
        let header = "v1=deadbeef".to_string();
        assert!(verify_signature("{}", &header, "whsec_test", 1_700_000_000).is_err());
    }
}
