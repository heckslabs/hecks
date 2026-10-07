use super::{instances_for, respond};
use crate::dispatch;
use crate::ir::{ir, newsletter_issues_provider};
use crate::journal::LineageConfig;
use crate::lambda_client::LambdaInvoker;
use hmac::{Hmac, Mac};
use serde_json::{json, Value};
use sha2::Sha256;
use std::path::Path;
use tokio::sync::Mutex;
use tokio_postgres::Client;

type HmacSha256 = Hmac<Sha256>;

// POST /webhooks/resend: Resend reports that a delivered issue was opened or
// clicked. The first open and the first click of each delivery are recorded on
// its Delivery (`RecordOpen` / `RecordClick`, which refuse a repeat). The
// delivery is found by the Resend message id stored when the issue was sent.
// Served under the same gate as the other newsletter routes, and only when
// RESEND_WEBHOOK_SECRET (the endpoint's `whsec_` signing secret) is set.

const SECRET_VARIABLE: &str = "RESEND_WEBHOOK_SECRET";
// Resend signs with Svix, whose default replay window is five minutes.
const TOLERANCE_SECONDS: i64 = 300;

#[derive(Debug, PartialEq)]
enum Tracked {
    Open,
    Click,
}

impl Tracked {
    fn command_suffix(&self) -> &'static str {
        match self {
            Tracked::Open => "RecordOpen",
            Tracked::Click => "RecordClick",
        }
    }
}

#[allow(clippy::too_many_arguments)]
pub(super) async fn resend_webhook_route(
    method: &str,
    path: &str,
    raw_body: &str,
    headers: Option<&Value>,
    client: &Mutex<Client>,
    wasm_path: &Path,
    config: &LineageConfig,
    invoker: &dyn LambdaInvoker,
) -> Option<Value> {
    if method != "POST" || path != "/webhooks/resend" {
        return None;
    }
    let header = |name: &str| headers.and_then(|h| h.get(name)).and_then(|v| v.as_str()).unwrap_or("");
    let secret = std::env::var(SECRET_VARIABLE).unwrap_or_default();
    if secret.trim().is_empty() {
        return Some(respond(503, "text/plain", &format!("{SECRET_VARIABLE} is not set, so Resend events cannot be verified")));
    }
    if let Err(reason) = verify(raw_body, header("svix-id"), header("svix-timestamp"), header("svix-signature"), secret.trim(), unix_now()) {
        return Some(respond(400, "text/plain", &reason));
    }
    let event: Value = match serde_json::from_str(raw_body) {
        Ok(v) => v,
        Err(_) => return Some(respond(400, "text/plain", "invalid JSON")),
    };
    let Some((tracked, message_id)) = tracked_event(&event) else {
        return Some(respond(200, "text/plain", ""));
    };
    let Some(provider) = ir().and_then(newsletter_issues_provider) else {
        return Some(respond(200, "text/plain", ""));
    };
    // `record_delivery` names `<Chapter>::Delivery.Record`; the open and click
    // commands sit on the same aggregate.
    let Some(delivery_aggregate) = provider.record_delivery.rsplit_once('.').map(|(aggregate, _)| aggregate.to_string()) else {
        return Some(respond(200, "text/plain", ""));
    };
    let read = match dispatch::read(client, wasm_path).await {
        Ok(r) => r,
        Err(e) => return Some(respond(500, "text/plain", &format!("{e:#}"))),
    };
    let Some(delivery_id) = delivery_for(&instances_for(&read, &format!("{delivery_aggregate}#")), &message_id) else {
        // A message this site did not send as a newsletter (a receipt, a
        // confirmation): nothing to record, and a 200 stops Resend's retries.
        return Some(respond(200, "text/plain", ""));
    };
    let occurred_at = json!({ "occurred_at": { "value": occurred_at(&event) } });
    let verb = format!("{delivery_aggregate}.{}", tracked.command_suffix());
    // A refusal is a repeat (the first open or click is already recorded):
    // benign, and 200 tells Resend not to retry.
    match dispatch::handle_routed(client, wasm_path, &verb, json!(delivery_id), occurred_at, None, config, invoker).await {
        Err(e) => Some(respond(500, "text/plain", &format!("{e:#}"))),
        Ok(_) => Some(respond(200, "text/plain", "")),
    }
}

fn unix_now() -> i64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0)
}

// What the event is and which sent message it is about; `None` for any event
// type nothing here records.
fn tracked_event(event: &Value) -> Option<(Tracked, String)> {
    let tracked = match event.get("type")?.as_str()? {
        "email.opened" => Tracked::Open,
        "email.clicked" => Tracked::Click,
        _ => return None,
    };
    let message_id = event.get("data")?.get("email_id")?.as_str()?.to_string();
    Some((tracked, message_id))
}

// The event's own time in seconds; the arrival time when it carries none.
fn occurred_at(event: &Value) -> i64 {
    event
        .get("created_at")
        .and_then(|v| v.as_str())
        .and_then(parse_rfc3339_seconds)
        .unwrap_or_else(unix_now)
}

// `2026-10-06T21:59:20.123Z` or `2026-10-06T21:59:20+00:00` as unix seconds.
fn parse_rfc3339_seconds(text: &str) -> Option<i64> {
    let (date, time) = text.split_once('T')?;
    let mut ymd = date.split('-').map(|p| p.parse::<i64>().ok());
    let (year, month, day) = (ymd.next()??, ymd.next()??, ymd.next()??);
    let clock: String = time.chars().take_while(|c| c.is_ascii_digit() || *c == ':').collect();
    let mut hms = clock.split(':').map(|p| p.parse::<i64>().ok());
    let (hour, minute, second) = (hms.next()??, hms.next()??, hms.next().flatten().unwrap_or(0));
    // Days since 1970-01-01 (Howard Hinnant's civil-from-days, inverted).
    let year = if month <= 2 { year - 1 } else { year };
    let era = year.div_euclid(400);
    let year_of_era = year - era * 400;
    let shifted_month = (month + 9) % 12;
    let day_of_year = (153 * shifted_month + 2) / 5 + day - 1;
    let day_of_era = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year;
    let days = era * 146097 + day_of_era - 719468;
    Some(days * 86400 + hour * 3600 + minute * 60 + second)
}

// The id of the delivery whose stored Resend message id is `message_id`.
fn delivery_for(deliveries: &[(String, Value)], message_id: &str) -> Option<String> {
    deliveries
        .iter()
        .find(|(_, state)| state.get("message_id").and_then(|m| m.get("value")).and_then(|v| v.as_str()) == Some(message_id))
        .map(|(id, _)| id.clone())
}

// Svix signs `<id>.<timestamp>.<raw body>` with the key inside the `whsec_`
// secret, base64 (`v1,<signature>`, several space-separated while a secret is
// being rotated). `now` is a parameter so a test can hold time fixed.
fn verify(payload: &str, id: &str, timestamp: &str, signatures: &str, secret: &str, now: i64) -> Result<(), String> {
    if id.is_empty() || timestamp.is_empty() || signatures.is_empty() {
        return Err("missing svix-id, svix-timestamp or svix-signature header".to_string());
    }
    let sent: i64 = timestamp.parse().map_err(|_| "svix-timestamp is not a number".to_string())?;
    if (now - sent).abs() > TOLERANCE_SECONDS {
        return Err(format!("timestamp {sent} is outside the {TOLERANCE_SECONDS}s tolerance (now: {now})"));
    }
    let key = base64_decode(secret.strip_prefix("whsec_").unwrap_or(secret)).ok_or_else(|| "webhook secret is not valid base64".to_string())?;
    let mut mac = HmacSha256::new_from_slice(&key).map_err(|e| format!("webhook secret unusable as an HMAC key: {e}"))?;
    mac.update(format!("{id}.{timestamp}.{payload}").as_bytes());
    let expected = mac.finalize().into_bytes();
    let matches = signatures
        .split(' ')
        .filter_map(|candidate| candidate.strip_prefix("v1,"))
        .filter_map(base64_decode)
        .any(|signature| constant_time_eq(&signature, &expected));
    if matches {
        Ok(())
    } else {
        Err("signature does not match — wrong secret, or the payload was tampered with in transit".to_string())
    }
}

fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    a.len() == b.len() && a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

// Standard base64, padded or not; `None` on any other character.
fn base64_decode(text: &str) -> Option<Vec<u8>> {
    let mut out = Vec::with_capacity(text.len() * 3 / 4);
    let (mut bits, mut have) = (0u32, 0u32);
    for c in text.trim_end_matches('=').bytes() {
        let value = match c {
            b'A'..=b'Z' => c - b'A',
            b'a'..=b'z' => c - b'a' + 26,
            b'0'..=b'9' => c - b'0' + 52,
            b'+' => 62,
            b'/' => 63,
            _ => return None,
        } as u32;
        bits = (bits << 6) | value;
        have += 6;
        if have >= 8 {
            have -= 8;
            out.push((bits >> have) as u8);
            bits &= (1 << have) - 1;
        }
    }
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    const SECRET: &str = "whsec_c2VjcmV0LWtleQ=="; // "secret-key"

    fn base64_encode(bytes: &[u8]) -> String {
        const TABLE: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        let mut out = String::new();
        for chunk in bytes.chunks(3) {
            let n = chunk.iter().enumerate().fold(0u32, |acc, (i, b)| acc | (*b as u32) << (16 - 8 * i));
            for i in 0..=chunk.len() {
                out.push(TABLE[(n >> (18 - 6 * i) & 63) as usize] as char);
            }
            out.extend(std::iter::repeat_n('=', 3 - chunk.len()));
        }
        out
    }

    fn signed(id: &str, timestamp: &str, body: &str) -> String {
        let mut mac = HmacSha256::new_from_slice(b"secret-key").unwrap();
        mac.update(format!("{id}.{timestamp}.{body}").as_bytes());
        format!("v1,{}", base64_encode(&mac.finalize().into_bytes()))
    }

    #[test]
    fn base64_round_trips_with_and_without_padding() {
        for sample in [&b""[..], b"f", b"fo", b"foo", b"foob", b"secret-key"] {
            let encoded = base64_encode(sample);
            assert_eq!(base64_decode(&encoded).unwrap(), sample);
            assert_eq!(base64_decode(encoded.trim_end_matches('=')).unwrap(), sample);
        }
        assert!(base64_decode("not base64!").is_none());
    }

    #[test]
    fn a_correctly_signed_event_verifies() {
        let signature = signed("msg_1", "1000", "{}");
        assert!(verify("{}", "msg_1", "1000", &signature, SECRET, 1000).is_ok());
    }

    #[test]
    fn any_one_of_several_rotating_signatures_may_match() {
        let signature = format!("v1,AAAA {}", signed("msg_1", "1000", "{}"));
        assert!(verify("{}", "msg_1", "1000", &signature, SECRET, 1000).is_ok());
    }

    #[test]
    fn a_tampered_body_or_wrong_secret_is_refused() {
        let signature = signed("msg_1", "1000", "{}");
        assert!(verify("{\"x\":1}", "msg_1", "1000", &signature, SECRET, 1000).is_err());
        assert!(verify("{}", "msg_1", "1000", &signature, "whsec_b3RoZXI=", 1000).is_err());
    }

    #[test]
    fn a_stale_or_unsigned_event_is_refused() {
        let signature = signed("msg_1", "1000", "{}");
        assert!(verify("{}", "msg_1", "1000", &signature, SECRET, 1000 + TOLERANCE_SECONDS + 1).is_err());
        assert!(verify("{}", "", "1000", &signature, SECRET, 1000).is_err());
        assert!(verify("{}", "msg_1", "soon", &signature, SECRET, 1000).is_err());
    }

    #[test]
    fn opens_and_clicks_name_their_message_and_everything_else_is_ignored() {
        let open = json!({ "type": "email.opened", "data": { "email_id": "re_1" } });
        assert_eq!(tracked_event(&open), Some((Tracked::Open, "re_1".to_string())));
        let click = json!({ "type": "email.clicked", "data": { "email_id": "re_2" } });
        assert_eq!(tracked_event(&click), Some((Tracked::Click, "re_2".to_string())));
        assert_eq!(tracked_event(&json!({ "type": "email.delivered", "data": { "email_id": "re_3" } })), None);
        assert_eq!(tracked_event(&json!({ "type": "email.opened", "data": {} })), None);
    }

    #[test]
    fn the_delivery_is_found_by_its_stored_message_id() {
        let deliveries = vec![
            ("issue-1:a@b.com".to_string(), json!({ "message_id": { "value": "re_1" } })),
            ("issue-1:c@d.com".to_string(), json!({ "message_id": { "value": "re_2" } })),
        ];
        assert_eq!(delivery_for(&deliveries, "re_2").as_deref(), Some("issue-1:c@d.com"));
        assert_eq!(delivery_for(&deliveries, "re_9"), None);
    }

    #[test]
    fn the_event_time_is_read_as_unix_seconds() {
        assert_eq!(parse_rfc3339_seconds("1970-01-02T00:00:01.500Z"), Some(86401));
        assert_eq!(parse_rfc3339_seconds("2026-10-06T21:59:20+00:00"), Some(1_791_323_960));
        assert_eq!(parse_rfc3339_seconds("yesterday"), None);
    }

    #[test]
    fn the_commands_are_the_open_and_click_records() {
        assert_eq!(Tracked::Open.command_suffix(), "RecordOpen");
        assert_eq!(Tracked::Click.command_suffix(), "RecordClick");
    }
}
