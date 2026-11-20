//! What Stripe's answers come to: the business's name, a created webhook endpoint, an embedded
//! session, or the reason there is none. No reason quotes a key or a reply body.

use crate::hecks::adapters::http_out::{Refusal, Reply};
use crate::hecks::adapters::stripe::{EmbeddedSession, Endpoint, WebhookRefusal};
use serde_json::Value;

/// The reply body as JSON, `Null` when it is not JSON.
pub fn json(body: &[u8]) -> Value {
    serde_json::from_slice(body).unwrap_or(Value::Null)
}

/// The business name Stripe has for an account: its profile name, else its dashboard display
/// name, else its email.
pub fn business_name(account: &Value) -> Option<String> {
    [
        account.pointer("/business_profile/name"),
        account.pointer("/settings/dashboard/display_name"),
        account.get("email"),
    ]
    .into_iter()
    .flatten()
    .find_map(|v| v.as_str().filter(|s| !s.is_empty()))
    .map(String::from)
}

/// The endpoint a webhook reply created: 401 or 403 is a permission refusal, any other failure or
/// an answer without both an id and a secret is `other`.
pub fn endpoint(reply: &Reply) -> Result<Endpoint, WebhookRefusal> {
    if matches!(reply.status, 401 | 403) {
        return Err(WebhookRefusal::Permission);
    }
    if !(200..300).contains(&reply.status) {
        return Err(WebhookRefusal::Other);
    }
    let body = json(&reply.body);
    match (text(&body, "id"), text(&body, "secret")) {
        (Some(id), Some(secret)) => Ok(Endpoint { id, secret }),
        _ => Err(WebhookRefusal::Other),
    }
}

/// The embedded session a checkout reply opened, or why not: Stripe's own message when it
/// refused, and never the body, which may carry the client secret.
pub fn session(reply: &Reply) -> Result<EmbeddedSession, String> {
    let body: Value = serde_json::from_slice(&reply.body)
        .map_err(|_| "error decoding response body".to_string())?;
    if !(200..300).contains(&reply.status) {
        let message = body
            .pointer("/error/message")
            .and_then(Value::as_str)
            .unwrap_or("unknown Stripe error");
        return Err(format!(
            "Stripe checkout session creation failed ({}): {message}",
            status_line(reply.status)
        ));
    }
    let present = |field: &str| body.get(field).and_then(Value::as_str).map(String::from);
    match (present("id"), present("client_secret")) {
        (Some(session_id), Some(client_secret)) => Ok(EmbeddedSession {
            session_id,
            client_secret,
        }),
        _ => Err("Stripe's response carried no \"id\" and \"client_secret\" for the embedded session"
            .to_string()),
    }
}

/// The reason a request that never reached Stripe gives.
pub fn unreachable(refusal: Refusal) -> String {
    match refusal {
        Refusal::Undeclared(host) => format!("Stripe unreachable: {host} is not granted"),
        Refusal::Failed(why) => format!("Stripe unreachable: {why}"),
    }
}

fn text(body: &Value, field: &str) -> Option<String> {
    body.get(field)
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .map(String::from)
}

/// The status as the host's HTTP client names it (`400 Bad Request`), or the bare code.
fn status_line(status: u16) -> String {
    let reason = match status {
        400 => "Bad Request",
        401 => "Unauthorized",
        402 => "Payment Required",
        403 => "Forbidden",
        404 => "Not Found",
        409 => "Conflict",
        429 => "Too Many Requests",
        500 => "Internal Server Error",
        502 => "Bad Gateway",
        503 => "Service Unavailable",
        _ => return status.to_string(),
    };
    format!("{status} {reason}")
}
