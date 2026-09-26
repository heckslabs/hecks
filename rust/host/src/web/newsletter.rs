use super::{instances_for, last_refusal, respond};
use crate::dispatch;
use crate::ir::{ir, newsletter_provider, NewsletterProvider};
use crate::journal::LineageConfig;
use crate::lambda_client::LambdaInvoker;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::path::Path;
use tokio::sync::Mutex;
use tokio_postgres::Client;

// ---- newsletter: guest-facing subscribe/confirm/unsubscribe, admin
// listing ----------------------------------------------------------
// Ported from http_server.rb's own POST /newsletter/subscribers, GET
// /newsletter/subscribers, GET /newsletter/subscribers/confirm, and GET
// /newsletter/subscribers/unsubscribe. Confirm/unsubscribe were NOT
// ported when this module was first written ("stay Ruby-only for now,
// reached through LIFEADELICS_DOMAIN_SERVICE_URL pointing at the Ruby
// process in whichever environment still runs it") — a real gap, since
// production runs THIS host exclusively, with no Ruby fallback at all:
// confirmed live, every real unsubscribe link 401'd ("sign in first",
// auth_gate's own refusal — these two paths fell through to it since
// nothing here recognized them, and neither is in UNGATED_PATHS), never
// so much as reaching a "no such subscriber" 404. Same match-arm
// ordering concern http_server.rb's own comment on this exact pair
// flags for Sinatra (declared before a generic /:email route so
// "confirm"/"unsubscribe" can't be treated as an email) doesn't apply
// here — Rust match on an exact (method, path) tuple has no such
// prefix/wildcard ambiguity to order around.
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

/// POST /newsletter/subscribers — Subscribe on a new email, AddName on a
/// returning one (the two-step public signup form's own step
/// 1/step 2 — NewsletterSubscribeForm.astro's own header has the full
/// reasoning). The response carries the subscriber's resulting status,
/// `pending` for a new subscriber.
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
    }

    // Confirm is not dispatched here: a new subscriber stays `pending`
    // until they follow the confirm link (the route below). This route only
    // reports where the subscriber ended up.
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

/// GET /newsletter/subscribers — every subscriber, alphabetically by
/// email (Newsletter::Subscriber.Listing's own declared order) — the
/// admin overview/Users pages' own read. Read directly off `instances`
/// rather than `dispatch::query` (which would need the qualified
/// question name resolved against `config.domain`, but Subscriber lives
/// under "Newsletter", not `config.domain` -- same cross-chapter
/// reasoning `instances_for(&read, "Payments::Payment#")` above already
/// follows for reading Payment).
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

/// GET /newsletter/subscribers/confirm?email=... — ported field-for-field
/// from http_server.rb's own route. NO SIGNED TOKEN, matching that
/// route's own known, flagged gap (subscriber.bluebook's own header):
/// anyone who knows an email can confirm it. Idempotent the same way —
/// Confirm only dispatches when the subscriber is actually `pending`
/// (its own `given` refuses a second attempt outright), so a guest
/// double-clicking, or a mail client prefetching the link, still lands
/// on the same success response instead of a 422.
async fn newsletter_confirm_route(provider: &NewsletterProvider, query: &HashMap<String, String>, client: &Mutex<Client>, wasm_path: &Path, config: &LineageConfig, invoker: &dyn LambdaInvoker) -> Value {
    let Some(email) = query.get("email") else {
        return respond(400, "application/json", &json!({"error": "email"}).to_string());
    };

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

/// GET /newsletter/subscribers/unsubscribe?email=... — same shape as
/// newsletter_confirm_route above, ported from http_server.rb's own
/// route (same "no signed token" gap, same idempotency reasoning:
/// Unsubscribe's own `given` only accepts a pending or confirmed
/// subscriber, so a repeat click on an already-unsubscribed row would
/// otherwise 422 instead of showing the same success page). This is the
/// one newsletter-unsubscribed.astro's own server-side fetch calls —
/// unreachable before this route existed (confirmed live: fell through
/// to auth_gate's 401, never a 404, since neither this path nor
/// /confirm was in UNGATED_PATHS and nothing recognized either one).
async fn newsletter_unsubscribe_route(provider: &NewsletterProvider, query: &HashMap<String, String>, client: &Mutex<Client>, wasm_path: &Path, config: &LineageConfig, invoker: &dyn LambdaInvoker) -> Value {
    let Some(email) = query.get("email") else {
        return respond(400, "application/json", &json!({"error": "email"}).to_string());
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
