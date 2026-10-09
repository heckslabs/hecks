//! Stripe checkout and webhook mechanics for the registration routes: HMAC
//! signature verification, an embedded Checkout Session, and a mock session.

use hmac::{Hmac, Mac};
use serde_json::Value;
use sha2::Sha256;

type HmacSha256 = Hmac<Sha256>;

pub struct SignatureError(pub String);

impl std::fmt::Display for SignatureError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.0)
    }
}

// Signs `<timestamp>.<raw body>`, the exact bytes Stripe sent -- re-serializing
// the JSON would disagree on whitespace or key order and break every match.
// `now` is a parameter, not read internally, so a test can hold time fixed.
// `tolerance_seconds` is the freshness window the Checkout bluebook declares
// (`WebhookReceipt.tolerance`, read from the IR): it guards against a replayed
// old payload even against a leaked (not yet rotated) secret.
pub fn verify_signature(payload: &str, header: &str, secret: &str, now: i64, tolerance_seconds: i64) -> Result<(), SignatureError> {
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
    if (now - timestamp).abs() > tolerance_seconds {
        return Err(SignatureError(format!(
            "timestamp {timestamp} is outside the {tolerance_seconds}s tolerance (now: {now})"
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

// A bare `==` short-circuits at the first differing byte, opening a timing
// side-channel on the signature comparison, so this compares every byte.
fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    a.iter().zip(b.iter()).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

// Encodes success_url/cancel_url as query params, matching the Ruby local
// checkout adapter's own `URI.encode_www_form` output exactly.
pub fn mock_checkout_session(registration_id: &str, success_url: &str, cancel_url: &str, site_url: &str) -> String {
    let mut url = reqwest::Url::parse(&format!("{site_url}/pay/{registration_id}.html"))
        .unwrap_or_else(|_| reqwest::Url::parse("http://invalid.invalid/").unwrap());
    url.query_pairs_mut().append_pair("success_url", success_url).append_pair("cancel_url", cancel_url);
    url.to_string()
}

// Embedded, not Stripe-hosted, so Stripe returns a `client_secret` instead of
// a `url`. `ui_mode` must be `embedded_page`; Stripe rejects the older
// `embedded` value. No success_url/cancel_url: the browser stays on the site
// and learns of completion from Stripe.js, with the webhook settling payment.

// Pinned: `embedded_page` needs this version line, not whatever the account defaults to.
pub const STRIPE_API_VERSION: &str = "2026-04-22.dahlia";

pub struct StripeAuth<'a> {
    pub api_key: &'a str,
    pub base_url: &'a str,
}

pub struct EmbeddedSession {
    pub session_id: String,
    pub client_secret: String,
}

// 31, not 30: Stripe requires an expiry at least 30 minutes out. This floor is a
// fact about the processor, so it lives here in the adapter; the domain declares
// only how long a session holds its seat (`CheckoutSession.hold`), and a hold
// shorter than the floor is raised to it.
pub const STRIPE_MIN_HOLD_SECONDS: i64 = 31 * 60;

/// The hold actually sent to Stripe for a domain hold of `hold_seconds`.
pub fn effective_hold_seconds(hold_seconds: i64) -> i64 {
    hold_seconds.max(STRIPE_MIN_HOLD_SECONDS)
}

pub fn session_expires_at(now: i64, hold_seconds: i64) -> i64 {
    now + effective_hold_seconds(hold_seconds)
}

// Errors carry Stripe's message when it refuses, never a secret.
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

    const TOLERANCE_SECONDS: i64 = 300;

    fn sign(secret: &str, timestamp: i64, payload: &str) -> String {
        let signed_payload = format!("{timestamp}.{payload}");
        let mut mac = HmacSha256::new_from_slice(secret.as_bytes()).unwrap();
        mac.update(signed_payload.as_bytes());
        hex_encode(&mac.finalize().into_bytes())
    }

    #[test]
    fn mock_checkout_session_matches_local_checkouts_own_pay_page_shape() {
        // The Ruby local checkout adapter's own real output, same three parts: this
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

        assert!(verify_signature(payload, &header, secret, now, TOLERANCE_SECONDS).is_ok());
    }

    #[test]
    fn a_payload_tampered_with_after_signing_is_rejected() {
        let secret = "whsec_test";
        let now = 1_700_000_000;
        let header = format!("t={now},v1={}", sign(secret, now, r#"{"type":"checkout.session.completed"}"#));

        // Same header, different body — exactly what an attacker
        // intercepting and rewriting the request in transit would send.
        let tampered = r#"{"type":"checkout.session.expired"}"#;
        assert!(verify_signature(tampered, &header, secret, now, TOLERANCE_SECONDS).is_err());
    }

    #[test]
    fn the_wrong_secret_is_rejected() {
        let payload = r#"{"type":"checkout.session.completed"}"#;
        let now = 1_700_000_000;
        let header = format!("t={now},v1={}", sign("whsec_real", now, payload));

        assert!(verify_signature(payload, &header, "whsec_wrong", now, TOLERANCE_SECONDS).is_err());
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
        assert!(verify_signature(payload, &header, secret, much_later, TOLERANCE_SECONDS).is_err());
    }

    #[test]
    fn a_hold_shorter_than_stripes_floor_is_raised_to_it() {
        assert_eq!(effective_hold_seconds(1800), STRIPE_MIN_HOLD_SECONDS);
        assert_eq!(effective_hold_seconds(3600), 3600);
        assert_eq!(session_expires_at(1_000, 1800), 1_000 + STRIPE_MIN_HOLD_SECONDS);
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

        assert!(verify_signature(payload, &header, old_secret, now, TOLERANCE_SECONDS).is_ok());
        assert!(verify_signature(payload, &header, new_secret, now, TOLERANCE_SECONDS).is_ok());
    }

    #[test]
    fn a_header_with_no_v1_at_all_is_rejected() {
        let now = 1_700_000_000;
        let header = format!("t={now}");
        assert!(verify_signature("{}", &header, "whsec_test", now, TOLERANCE_SECONDS).is_err());
    }

    #[test]
    fn a_header_with_no_timestamp_at_all_is_rejected() {
        let header = "v1=deadbeef".to_string();
        assert!(verify_signature("{}", &header, "whsec_test", 1_700_000_000, TOLERANCE_SECONDS).is_err());
    }
}
