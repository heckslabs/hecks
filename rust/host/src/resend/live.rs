//! The native Resend delivery: the payload, the retry on 429 and the mapping of Resend's answer,
//! over the host's own `reqwest` client. The component in `rust/adapters/resend` holds the same.

use super::{Account, Delivery, Email};
use serde_json::{json, Value};
use std::time::Duration;

const MAX_ATTEMPTS: u32 = 4;
const DEFAULT_RETRY_SECS: u64 = 1;
const MAX_RETRY_SECS: u64 = 5;

fn payload(from: &str, reply_to: Option<&str>, email: &Email<'_>) -> Value {
    let mut payload = json!({ "from": from, "to": [email.to], "subject": email.subject });
    if let Some(reply_to) = reply_to {
        payload["reply_to"] = json!(reply_to);
    }
    let content_key = if email.body.trim_start().starts_with('<') {
        "html"
    } else {
        "text"
    };
    payload[content_key] = json!(email.body);
    if let Some(url) = email.unsubscribe_url {
        payload["headers"] = json!({ "List-Unsubscribe": format!("<{url}>") });
    }
    payload
}

fn retry_delay(response: &reqwest::Response) -> Duration {
    let secs = response
        .headers()
        .get("retry-after")
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.trim().parse::<u64>().ok())
        .unwrap_or(DEFAULT_RETRY_SECS);
    Duration::from_secs(secs.min(MAX_RETRY_SECS))
}

pub(super) async fn deliver(
    http: &reqwest::Client,
    account: &Account,
    email: &Email<'_>,
) -> Delivery {
    let body = payload(&account.from, account.reply_to.as_deref(), email);
    for attempt in 1..=MAX_ATTEMPTS {
        let response = match http
            .post(format!("{}/emails", account.base_url))
            .bearer_auth(&account.api_key)
            .json(&body)
            .send()
            .await
        {
            Ok(r) => r,
            Err(e) => return Delivery::failed(format!("resend unreachable: {}", e.without_url())),
        };
        let status = response.status();
        if status.as_u16() == 429 && attempt < MAX_ATTEMPTS {
            tokio::time::sleep(retry_delay(&response)).await;
            continue;
        }
        let answer: Value = response.json().await.unwrap_or(Value::Null);
        if status.is_success() {
            return answer.get("id").and_then(|v| v.as_str()).map_or_else(
                || Delivery::failed("resend accepted the email but returned no id"),
                |id| Delivery::sent(id.to_string()),
            );
        }
        let message = answer
            .get("message")
            .and_then(|v| v.as_str())
            .map(String::from);
        return Delivery::failed(message.unwrap_or_else(|| format!("resend answered {status}")));
    }
    Delivery::failed("resend kept rate limiting this email")
}
