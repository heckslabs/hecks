// LIFEADELICS' CHECKOUT/WEBHOOK BOUNDARY — the two mechanics
// adapters/http_server.rb (Ruby, lifeadelics repo) hand-rolls against
// the `stripe` gem: opening a real Stripe Checkout Session (the OUTBOUND
// half of lifeadelics.hecksagon's own "checkout" port,
// Registration.opened_by) and verifying a Stripe webhook's own
// HMAC-SHA256 signature scheme (the INBOUND half, driving Payment's
// PaymentGateway port). Both hand-written here, not IR-driven —
// `rust/project/ports.rb`'s own `emit_port_operation` covers only
// INBOUND port operations (PaymentGateway.Succeeded/Failed, dispatched
// from web.rs's own checkout_route through the already-proven
// port-operation + policy-reaction codegen path); no domain in this
// corpus has an OUTBOUND driving port or a webhook-shaped signature
// scheme to generalize this against yet, so it stays a real, scoped
// specialization (web.rs's own "LIFEADELICS-SPECIFIC GLUE" header has
// the fuller reasoning) rather than a new IR capability invented
// speculatively for a population of one.
//
// EQUIVALENCE-GAP PLAN 3.3 — CONSIDERED, DECLINED, checked directly
// against this checkout rather than assumed: population here is
// actually ZERO reachable examples, not one. There is no Lifeadelics
// `.bluebook`/`.hecksagon` source anywhere in this checkout to design a
// second `signature_scheme`/`opens_external_call` DSL word against —
// deploy/lifeadelics{,-demo} were deleted outright (`eb3bd853`, commit
// message: "generated from ephemeral /tmp paths during tool testing,
// not the real client config... which already lives in
// ~/Projects/lifeadelics/deploy-aws"), and `rust/dist/` carries no
// `lifeadelics.{wasm,ir.json}` either — every artifact this task would
// need to validate against, gone, not merely out of reach in a private
// repo. A synthetic-only fixture would be the ONLY thing exercising new
// IR/DSL surface this checkout could ever build, the same "invented
// generality with no real backing" reasoning process_manager.rb's own
// Saga/undoes comment already declines building compensation-ordering
// for — except that item at least had one real corpus example (Banking's
// Settlement saga) to check a design against; this has none.
//
// A SEPARATE, REAL BLOCKER surfaced investigating this anyway, worth
// recording even though the feature above stays declined: the plan's
// own proposed gate ("does `domain_ir` declare an `external_gateways`
// entry") cannot work as designed for Lifeadelics regardless, because
// `web.rs`'s own header (below) states `ir()` never resolves for a
// Shared-mode domain at all — `HECKS_IR_PATH` is only emitted by
// `bin/project_deploy` when `rust_web` is true (that script's own
// `rust_web ? %(\n HECKS_IR_PATH: ...) : ""` conditional), yet
// `rust/host/src/main.rs`'s own boot sequence reads `ir::ir().ok_or(...)?`
// UNCONDITIONALLY, for every domain regardless of web mode — confirmed
// live against Banking's own committed `deploy/banking/template.yaml`
// (Shared/`AuthType: AWS_IAM`, confirming `rust_web == false` there),
// which genuinely carries no `HECKS_IR_PATH` key at all. That is a real,
// separate, currently-live contradiction between `main.rs` and
// `bin/project_deploy` — unrelated to Lifeadelics specifically, not
// fixed here (a different subsystem, a different task), but flagged
// plainly rather than silently discovered and dropped.
//
// EQUIVALENCE-GAP PLAN 3.4 (orphaned `Payments::Payment` sweep) —
// ALSO CONSIDERED, ALSO DECLINED, checked against this same absence
// rather than assumed compatible with it. The DETECTION half is
// genuinely buildable correctly: `registrations_route`'s own
// `Payment.Initiate`/`Registration.Request` calls (below) already
// prove `reference` and `registration_id` are the SAME string, so "a
// Payment whose reference has no matching Registration" is a real,
// answerable query via `instances_for` against both prefixes, no
// guessing required. The ACTION half is not: the plan's own text
// already names the reason ("confirm the exact command name once
// domain source is available, or coordinate with whoever owns the
// private Lifeadelics repo") — this checkout has no way to know
// whether `Payments::Payment` even DECLARES a command for
// flagging/expiring a record, let alone its name or payload shape,
// since (as above) no `.bluebook` source for it exists here at all.
// Worse than 3.3's own case in one respect: even a route implementing
// ONLY the detection half would be entirely unverifiable in this
// checkout — `web.rs`'s own `lifeadelics_wasm_path()` test helper
// expects `rust/dist/lifeadelics.wasm`, which does not exist (the
// SAME absence 3.3's own investigation already confirmed), so there
// is no compiled artifact left to run new Lifeadelics-specific code
// against at all, not even to prove the read-only half correct.
// Shipping new, production-facing code with zero verification path in
// this environment — not "narrower than planned," genuinely untestable
// — is a different and worse thing than declining outright. The real
// admin-route stopgap the plan describes remains real, worthwhile,
// buildable follow-up work — in the repo that actually holds
// Lifeadelics' own source and can compile/test against it, not here.
//
// MOCK BY DEFAULT, REAL STRIPE OPT-IN — mirrors the Ruby app's own
// choice exactly (MockStripeAdapter unconditionally in every
// environment except a real deploy — bin/smoke_test's own header: "the
// same as every environment except a real deploy"), not a scaled-down
// version of it. `web.rs`'s own `stripe_api_key()`/`stripe_webhook_
// secret()` decide which side of the line a given deploy is on: an
// empty `STRIPE_API_KEY` (the World's own blank default, lifeadelics.
// world's own comment on why) means `mock_checkout_session` below,
// never a real network call; `STRIPE_WEBHOOK_SECRET` falls back to the
// SAME fixed, publicly-known, non-secret value adapters/http_server.rb
// hardcodes (`"whsec_mock_lifeadelics_fixed"`, ALSO what domain/bin/
// confirm_payment_manually signs against) — so a mock deploy needs zero
// Lambda environment configuration at all to be fully exercisable,
// registration through confirmation, matching Ruby's own zero-config
// mock story.

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
// hmac>...]" (more than one v1 during a secret-rotation window — ANY
// match is accepted, same as the gem), signed payload is exactly
// "<timestamp>.<raw body>", the RAW BYTES Stripe sent, never a
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
// differing byte. Compared as the HEX text the header actually carries
// (hmac's own `finalize()` gives a constant-time-comparable `CtOutput`
// for the RAW bytes, but this needs the same hex round-trip either way
// to line up against `header`'s own v1= values, so it's done by hand).
fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    a.iter().zip(b.iter()).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

// THE MOCK OUTBOUND SIDE — MockStripeAdapter's own `create_session`
// (vendor/hecks/lib/hecks/adapters/driven/mock_stripe_adapter.rb,
// the hecks gem's own generic stand-in), ported byte-for-byte:
// never reads price/product name (a real adapter needs them to build a
// session a payer actually sees; this only needs to look enough like
// one to swap in), and the URL it returns carries the SAME
// `registration_id` a real webhook's metadata would, so a caller
// signing its own synthetic webhook against it (confirm_payment_
// manually, a smoke test) has something real to key off of.
pub fn mock_checkout_session(registration_id: &str, success_url: &str) -> String {
    let separator = if success_url.contains('?') { "&" } else { "?" };
    format!("{success_url}{separator}mock_checkout=1&mock_registration_id={registration_id}")
}

// THE OUTBOUND SIDE — adapters/stripe/stripe.rb's own `create_session`,
// same four fields the Ruby version builds: currency hardcoded "usd"
// (same as Ruby — lifeadelics' own Event::Money value object carries no
// currency at all, see lifeadelics.bluebook's own comment on it), one
// line item, quantity 1, and the SAME metadata key ("registration_id")
// web.rs's own webhook route reads back to recover which Payment/
// Registration this session belongs to.
pub async fn create_checkout_session(
    api_key: &str,
    price_cents: i64,
    product_name: &str,
    registration_id: &str,
    success_url: &str,
    cancel_url: &str,
) -> anyhow::Result<String> {
    let unit_amount = price_cents.to_string();
    let params = [
        ("mode", "payment"),
        ("line_items[0][price_data][currency]", "usd"),
        ("line_items[0][price_data][unit_amount]", unit_amount.as_str()),
        ("line_items[0][price_data][product_data][name]", product_name),
        ("line_items[0][quantity]", "1"),
        ("metadata[registration_id]", registration_id),
        ("success_url", success_url),
        ("cancel_url", cancel_url),
    ];

    let response = reqwest::Client::new()
        .post("https://api.stripe.com/v1/checkout/sessions")
        .bearer_auth(api_key)
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

    body.get("url")
        .and_then(|v| v.as_str())
        .map(String::from)
        .ok_or_else(|| anyhow::anyhow!("Stripe's response carried no \"url\": {body}"))
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
    fn mock_checkout_session_matches_mock_stripe_adapters_own_exact_shape() {
        // mock_stripe_adapter.rb's own real output, reproduced byte for
        // byte: `"#{success_url}#{separator}mock_checkout=1&mock_
        // registration_id=#{registration_id}"`.
        let url = mock_checkout_session("REG-1", "https://example.com/yoga.html?registered=1");
        assert_eq!(url, "https://example.com/yoga.html?registered=1&mock_checkout=1&mock_registration_id=REG-1");
    }

    #[test]
    fn mock_checkout_session_uses_a_bare_question_mark_when_the_success_url_carries_no_query_string_yet() {
        let url = mock_checkout_session("REG-2", "https://example.com/yoga.html");
        assert_eq!(url, "https://example.com/yoga.html?mock_checkout=1&mock_registration_id=REG-2");
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

        // Same header, DIFFERENT body — exactly what an attacker
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

        // A REPLAYED webhook -- the signature is genuinely correct for
        // ITS OWN timestamp, which is exactly why the tolerance check has
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
