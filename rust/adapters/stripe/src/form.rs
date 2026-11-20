//! The form bodies Stripe's `POST` calls take, encoded as `application/x-www-form-urlencoded`
//! byte for byte as the host's HTTP client encodes a form.

use crate::hecks::adapters::stripe::{SessionRequest, WebhookRequest};

/// The webhook endpoint's URL, description and each event as `enabled_events[<index>]`.
pub fn webhook(wanted: &WebhookRequest) -> String {
    let mut pairs = vec![
        ("url".to_string(), wanted.url.clone()),
        ("description".to_string(), wanted.description.clone()),
    ];
    pairs.extend(
        wanted
            .events
            .iter()
            .enumerate()
            .map(|(index, event)| (format!("enabled_events[{index}]"), event.clone())),
    );
    encode(&pairs)
}

/// An embedded, one-line, one-seat payment session that never redirects and expires when asked.
pub fn session(wanted: &SessionRequest) -> String {
    let pairs: Vec<(String, String)> = [
        ("mode", "payment".to_string()),
        ("ui_mode", "embedded_page".to_string()),
        ("redirect_on_completion", "never".to_string()),
        ("expires_at", wanted.expires_at.to_string()),
        ("line_items[0][price_data][currency]", wanted.currency.clone()),
        ("line_items[0][price_data][unit_amount]", wanted.price_cents.to_string()),
        ("line_items[0][price_data][product_data][name]", wanted.product_name.clone()),
        ("line_items[0][quantity]", "1".to_string()),
        ("metadata[registration_id]", wanted.registration_id.clone()),
    ]
    .into_iter()
    .map(|(name, value)| (name.to_string(), value))
    .collect();
    encode(&pairs)
}

fn encode(pairs: &[(String, String)]) -> String {
    pairs
        .iter()
        .map(|(name, value)| format!("{}={}", escape(name), escape(value)))
        .collect::<Vec<_>>()
        .join("&")
}

/// Leaves ASCII letters, digits and `*-._` alone, writes a space as `+` and every other byte as
/// `%XX`, as the URL standard's form encoding does.
fn escape(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for byte in text.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'*' | b'-' | b'.' | b'_' => {
                out.push(char::from(byte));
            }
            b' ' => out.push('+'),
            _ => out.push_str(&format!("%{byte:02X}")),
        }
    }
    out
}
