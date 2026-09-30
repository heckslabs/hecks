#[cfg(test)]
use super::newsletter_send::unsubscribe_token;
use super::newsletter_send::unsubscribe_token_matches;
use super::{instances_for, last_refusal, respond};
use crate::auth;
use crate::dispatch;
use crate::ir::{ir, newsletter_provider, NewsletterProvider};
use crate::journal::LineageConfig;
use crate::lambda_client::LambdaInvoker;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::path::Path;
use tokio::sync::Mutex;
use tokio_postgres::Client;

#[cfg(test)]
mod tests;

// Guest-facing subscribe/confirm/unsubscribe routes, plus the admin listing.
// Served here (not passed to Ruby) so a signed link still resolves without one.
pub(super) async fn newsletter_route(
    method: &str,
    path: &str,
    query: &HashMap<String, String>,
    raw_body: &str,
    client: &Mutex<Client>,
    wasm_path: &Path,
    config: &LineageConfig,
    invoker: &dyn LambdaInvoker,
) -> Option<Value> {
    // The chapter that declares `provides "newsletter"` names the verbs
    // and the subscribing aggregate; a domain that attaches none serves
    // none of these routes.
    let provider = ir().and_then(newsletter_provider)?;
    match (method, path) {
        ("POST", "/newsletter/subscribers") => Some(newsletter_subscribe_route(&provider, raw_body, client, wasm_path, config, invoker).await),
        ("GET", "/newsletter/subscribers") => Some(newsletter_subscribers_list_route(&provider, client, wasm_path).await),
        ("GET", "/newsletter/subscribers/confirm") => Some(newsletter_confirm_route(&provider, query, client, wasm_path, config, invoker).await),
        ("GET", "/newsletter/subscribers/unsubscribe") => Some(newsletter_unsubscribe_route(&provider, query, client, wasm_path, config, invoker).await),
        _ => None,
    }
}

// Called twice by the two-step signup form: first without a name (Subscribe),
// then with one (AddName).
async fn newsletter_subscribe_route(
    provider: &NewsletterProvider,
    raw_body: &str,
    client: &Mutex<Client>,
    wasm_path: &Path,
    config: &LineageConfig,
    invoker: &dyn LambdaInvoker,
) -> Value {
    let body: Value = match serde_json::from_str(raw_body) {
        Ok(v) => v,
        Err(e) => return respond(400, "application/json", &json!({"error": format!("invalid JSON: {e}")}).to_string()),
    };
    let Some(email) = body.get("email").and_then(|v| v.as_str()) else {
        return respond(400, "application/json", &json!({"error": "email"}).to_string());
    };
    let first_name = body.get("first_name").and_then(|v| v.as_str()).filter(|s| !s.is_empty());
    let last_name = body.get("last_name").and_then(|v| v.as_str()).filter(|s| !s.is_empty());

    let read = match dispatch::read(client, wasm_path).await {
        Ok(r) => r,
        Err(e) => return respond(500, "text/plain", &format!("{e:#}")),
    };
    let existing = instances_for(&read, &provider.instance_prefix()).iter().any(|(id, _)| id == email);

    if existing {
        if let (Some(first), Some(last)) = (first_name, last_name) {
            let facts = json!({"first_name": {"value": first}, "last_name": {"value": last}});
            if let Err(e) = dispatch::handle_routed(client, wasm_path, &provider.add_name, json!(email), facts, None, config, invoker).await {
                return respond(500, "text/plain", &format!("{e:#}"));
            }
        }
    } else {
        let mut facts = json!({"email": {"value": email}});
        if let Some(first) = first_name {
            facts["first_name"] = json!({"value": first});
        }
        if let Some(last) = last_name {
            facts["last_name"] = json!({"value": last});
        }
        let outcome = match dispatch::handle_facts(client, wasm_path, &provider.subscribe, facts, None, config, invoker).await {
            Ok(o) => o,
            Err(e) => return respond(500, "text/plain", &format!("{e:#}")),
        };
        if !outcome.accepted {
            return respond(422, "application/json", &last_refusal(&outcome.result).to_string());
        }
        if let Err(failure) = confirm_if_pending(email, client, wasm_path, config, invoker).await {
            return failure;
        }
    }

    // A signup is confirmed on the spot: the address is subscribed without a
    // confirmation email. This route then reports where the subscriber ended up.
    let read = match dispatch::read(client, wasm_path).await {
        Ok(r) => r,
        Err(e) => return respond(500, "text/plain", &format!("{e:#}")),
    };
    let subscribers = instances_for(&read, &provider.instance_prefix());
    let Some((_, subscriber)) = subscribers.iter().find(|(id, _)| id == email) else {
        return respond(500, "text/plain", "subscriber vanished immediately after being written");
    };
    let status = subscriber.get("status").and_then(|v| v.as_str()).unwrap_or("pending");
    respond(200, "application/json", &json!({"email": email, "status": status}).to_string())
}

// Reads directly off `instances`, not `dispatch::query`: Subscriber lives
// under the Newsletter chapter, not `config.domain`, so the qualified
// question name would not resolve there.
async fn newsletter_subscribers_list_route(provider: &NewsletterProvider, client: &Mutex<Client>, wasm_path: &Path) -> Value {
    let read = match dispatch::read(client, wasm_path).await {
        Ok(r) => r,
        Err(e) => return respond(500, "text/plain", &format!("{e:#}")),
    };
    let mut subscribers: Vec<Value> = instances_for(&read, &provider.instance_prefix())
        .into_iter()
        .map(|(email, s)| {
            json!({
                "email": email,
                "status": s.get("status"),
                "first_name": s.get("first_name").and_then(|v| v.get("value")),
                "last_name": s.get("last_name").and_then(|v| v.get("value")),
            })
        })
        .collect();
    subscribers.sort_by(|a, b| a["email"].as_str().unwrap_or("").cmp(b["email"].as_str().unwrap_or("")));
    respond(200, "application/json", &json!(subscribers).to_string())
}

const CONFIRM_PURPOSE: &str = "newsletter-confirm";
const CONFIRM_TTL_SECS: u64 = 14 * 24 * 60 * 60;

// SESSION_SECRET; unset means no confirm link verifies. New signups are confirmed on
// the spot, so this only serves links emailed before that change.
fn confirm_secret() -> Option<String> {
    std::env::var("SESSION_SECRET").ok().filter(|s| !s.is_empty())
}

#[cfg(test)]
fn confirm_token(secret: &str, email: &str) -> String {
    auth::purpose_token(secret, CONFIRM_PURPOSE, json!({ "email": email }), CONFIRM_TTL_SECS)
}

fn confirm_token_matches(secret: &str, token: &str, email: &str) -> bool {
    auth::verify_purpose_token(secret, CONFIRM_PURPOSE, token)
        .and_then(|claims| claims.get("email").and_then(|v| v.as_str()).map(|signed| signed == email))
        .unwrap_or(false)
}

// Confirms a subscriber who is still `pending`; an already-confirmed or
// unsubscribed address is left alone (an unsubscribed one stays unsubscribed).
pub(super) async fn confirm_if_pending(email: &str, client: &Mutex<Client>, wasm_path: &Path, config: &LineageConfig, invoker: &dyn LambdaInvoker) -> Result<(), Value> {
    let Some(provider) = ir().and_then(newsletter_provider) else {
        return Ok(());
    };
    let read = dispatch::read(client, wasm_path).await.map_err(|e| respond(500, "text/plain", &format!("{e:#}")))?;
    let pending = instances_for(&read, &provider.instance_prefix())
        .iter()
        .any(|(id, subscriber)| id == email && subscriber.get("status").and_then(|v| v.as_str()) == Some("pending"));
    if pending {
        dispatch::handle_routed(client, wasm_path, &provider.confirm, json!(email), json!({}), None, config, invoker)
            .await
            .map_err(|e| respond(500, "text/plain", &format!("{e:#}")))?;
    }
    Ok(())
}

// The token must have been minted for this exact address (`confirm_token`);
// a missing, wrong or expired one refuses before any subscriber is touched.
// Idempotent: dispatches Confirm only while still `pending`, so a double
// click or link-prefetch lands on the same success response, not a 422.
async fn newsletter_confirm_route(provider: &NewsletterProvider, query: &HashMap<String, String>, client: &Mutex<Client>, wasm_path: &Path, config: &LineageConfig, invoker: &dyn LambdaInvoker) -> Value {
    let Some(email) = query.get("email") else {
        return respond(400, "application/json", &json!({"error": "email"}).to_string());
    };
    let signed = match (confirm_secret(), query.get("token")) {
        (Some(secret), Some(token)) => confirm_token_matches(&secret, token, email),
        _ => false,
    };
    if !signed {
        return respond(403, "application/json", &json!({"error": "this confirmation link is invalid or has expired"}).to_string());
    }

    let read = match dispatch::read(client, wasm_path).await {
        Ok(r) => r,
        Err(e) => return respond(500, "text/plain", &format!("{e:#}")),
    };
    let subscribers = instances_for(&read, &provider.instance_prefix());
    let Some((_, subscriber)) = subscribers.iter().find(|(id, _)| id == email) else {
        return respond(404, "application/json", &json!({"error": "no such subscriber"}).to_string());
    };

    if subscriber.get("status").and_then(|v| v.as_str()) == Some("pending") {
        if let Err(e) = dispatch::handle_routed(client, wasm_path, &provider.confirm, json!(email), json!({}), None, config, invoker).await {
            return respond(500, "text/plain", &format!("{e:#}"));
        }
    }

    let read = match dispatch::read(client, wasm_path).await {
        Ok(r) => r,
        Err(e) => return respond(500, "text/plain", &format!("{e:#}")),
    };
    let subscribers = instances_for(&read, &provider.instance_prefix());
    let status = subscribers.iter().find(|(id, _)| id == email).and_then(|(_, s)| s.get("status")).and_then(|v| v.as_str()).unwrap_or("pending");
    respond(200, "application/json", &json!({"email": email, "status": status}).to_string())
}

// 400 with no address; 403 for a missing, wrong, other-address or expired
// token, or no secret to check against. Otherwise Ok(email).
fn unsubscribe_authorized<'a>(secret: Option<&str>, query: &'a HashMap<String, String>) -> Result<&'a str, Value> {
    let Some(email) = query.get("email") else {
        return Err(respond(400, "application/json", &json!({"error": "email"}).to_string()));
    };
    let signed = match (secret, query.get("token")) {
        (Some(secret), Some(token)) => unsubscribe_token_matches(secret, token, email),
        _ => false,
    };
    if signed {
        Ok(email)
    } else {
        Err(respond(403, "application/json", &json!({"error": "this unsubscribe link is invalid or has expired"}).to_string()))
    }
}

// Same token/idempotency shape as newsletter_confirm_route: Unsubscribe's
// own `given` accepts a pending or confirmed subscriber, so a repeat click
// on an already-unsubscribed row lands on the same success response.
async fn newsletter_unsubscribe_route(provider: &NewsletterProvider, query: &HashMap<String, String>, client: &Mutex<Client>, wasm_path: &Path, config: &LineageConfig, invoker: &dyn LambdaInvoker) -> Value {
    let email = match unsubscribe_authorized(confirm_secret().as_deref(), query) {
        Ok(email) => email,
        Err(refusal) => return refusal,
    };

    let read = match dispatch::read(client, wasm_path).await {
        Ok(r) => r,
        Err(e) => return respond(500, "text/plain", &format!("{e:#}")),
    };
    let subscribers = instances_for(&read, &provider.instance_prefix());
    let Some((_, subscriber)) = subscribers.iter().find(|(id, _)| id == email) else {
        return respond(404, "application/json", &json!({"error": "no such subscriber"}).to_string());
    };

    if subscriber.get("status").and_then(|v| v.as_str()) != Some("unsubscribed") {
        if let Err(e) = dispatch::handle_routed(client, wasm_path, &provider.unsubscribe, json!(email), json!({}), None, config, invoker).await {
            return respond(500, "text/plain", &format!("{e:#}"));
        }
    }

    let read = match dispatch::read(client, wasm_path).await {
        Ok(r) => r,
        Err(e) => return respond(500, "text/plain", &format!("{e:#}")),
    };
    let subscribers = instances_for(&read, &provider.instance_prefix());
    let status = subscribers.iter().find(|(id, _)| id == email).and_then(|(_, s)| s.get("status")).and_then(|v| v.as_str()).unwrap_or("pending");
    respond(200, "application/json", &json!({"email": email, "status": status}).to_string())
}
