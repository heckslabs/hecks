// Stripe checkout and webhook mechanics for the registration routes:
// verifying a webhook's HMAC-SHA256 signature, opening an embedded Checkout
// Session, and the mock session used when no Stripe account is connected.
//
// These are hand-written rather than IR-driven. `rust/project/ports.rb`'s
// `emit_port_operation` covers inbound port operations only
// (PaymentGateway.Succeeded/Failed, dispatched from the registration routes
// through the port-operation and policy-reaction codegen path), and no domain
// has an outbound driving port or a webhook signature scheme to generalize
// against yet.
//
// Mock by default, real Stripe opt-in. payments.rs's `checkout_plan` decides
// which side of the line a request is on, from the tenant's own
// `PaymentConnection`: anything short of an enabled Stripe connection means
// `mock_checkout_session` below, never a network call. `STRIPE_WEBHOOK_SECRET`
// then falls back to the fixed, publicly known, non-secret
// `MOCK_STRIPE_WEBHOOK_SECRET` (web/registrations.rs), so a mock deploy needs
// no webhook secret configured to walk a registration through to
// confirmation. Tooling that signs webhooks with its own fixed string must
// set `STRIPE_WEBHOOK_SECRET` to that string.
//
// `HECKS_CHECKOUT_DOMAIN` (web.rs `render`) picks the domain these routes serve.

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
// A charge on the business's own Stripe account: that account's own key
// authenticates the call, so the session (and the money) belongs to it and no
// other account is named.
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
/// whatever default the account happens to have.
pub const STRIPE_API_VERSION: &str = "2026-04-22.dahlia";

/// How one Stripe call is authenticated and addressed: the business's own
/// secret key and the API base URL (`https://api.stripe.com` outside of tests).
pub struct StripeAuth<'a> {
    pub api_key: &'a str,
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

/// Opens an embedded Checkout Session for one registration on the business's
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

    let response = reqwest::Client::new()
        .post(format!("{}/v1/checkout/sessions", auth.base_url))
        .bearer_auth(auth.api_key)
        .header("Stripe-Version", STRIPE_API_VERSION)
        .form(&params)
        .send()
        .await?;

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
