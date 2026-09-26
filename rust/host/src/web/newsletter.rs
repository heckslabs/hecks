use super::newsletter_send::{site_url, unsubscribe_token, unsubscribe_token_matches, unsubscribe_url};
use super::{instances_for, last_refusal, respond};
use crate::auth;
use crate::dispatch;
use crate::ir::{ir, newsletter_provider, NewsletterProvider};
use crate::journal::LineageConfig;
use crate::lambda_client::LambdaInvoker;
use crate::resend::{Email, Mailer};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::path::Path;
use std::sync::OnceLock;
use tokio::sync::Mutex;
use tokio_postgres::Client;

mod cooldown;
#[cfg(test)]
mod tests;

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
        send_confirmation(email).await;
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

const CONFIRM_PURPOSE: &str = "newsletter-confirm";
const CONFIRM_TTL_SECS: u64 = 14 * 24 * 60 * 60;

/// The secret the confirm links are signed with: the session secret, the same
/// one every other signed token here uses. `None` while it is unset, in which
/// case no link can be signed and none is sent.
fn confirm_secret() -> Option<String> {
    std::env::var("SESSION_SECRET").ok().filter(|s| !s.is_empty())
}

fn confirm_token(secret: &str, email: &str) -> String {
    auth::purpose_token(secret, CONFIRM_PURPOSE, json!({ "email": email }), CONFIRM_TTL_SECS)
}

/// Whether `token` was minted for exactly this `email`, for this purpose, and
/// has not expired.
fn confirm_token_matches(secret: &str, token: &str, email: &str) -> bool {
    auth::verify_purpose_token(secret, CONFIRM_PURPOSE, token)
        .and_then(|claims| claims.get("email").and_then(|v| v.as_str()).map(|signed| signed == email))
        .unwrap_or(false)
}

/// The link in the confirmation email: the site's own confirm page, carrying
/// the address and the signed token (encoded, so a `+` in the local part
/// survives). That page calls back to the confirm route below.
fn confirm_url(site_url: &str, email: &str, token: &str) -> String {
    let mut url = reqwest::Url::parse(&format!("{site_url}/newsletter-confirmed.html")).unwrap_or_else(|_| reqwest::Url::parse("http://invalid.invalid/").unwrap());
    url.query_pairs_mut().append_pair("email", email).append_pair("token", token);
    url.to_string()
}

/// The one cooldown every confirmation email goes through. Per process: see
/// `ConfirmationCooldown`.
fn confirmation_cooldown() -> &'static cooldown::ConfirmationCooldown {
    static COOLDOWN: OnceLock<cooldown::ConfirmationCooldown> = OnceLock::new();
    COOLDOWN.get_or_init(|| cooldown::ConfirmationCooldown::new(cooldown::WINDOW, cooldown::CAPACITY))
}

fn confirmation_body(confirm_url: &str) -> String {
    format!(
        "Please confirm your newsletter subscription by opening this link:\n\n{confirm_url}\n\nIf you didn't ask for this, you can ignore this email and nothing will be sent to you.\n"
    )
}

/// Emails the signed confirm link to `email`. Best effort: a subscriber who
/// signs up must never see an error because mail is down or unconfigured, so
/// every failure is logged (without the address) and swallowed, and the
/// subscriber simply stays `pending`. An address that was already mailed a
/// confirmation inside the cooldown window is not mailed again, so the form
/// cannot be used to flood someone else's inbox.
pub(super) async fn send_confirmation(email: &str) {
    let Some(secret) = confirm_secret() else {
        eprintln!("newsletter: SESSION_SECRET is not set, so no confirmation link can be signed; the subscriber stays pending");
        return;
    };
    let mailer = match Mailer::from_env() {
        Ok(Some(mailer)) => mailer,
        Ok(None) => {
            eprintln!("newsletter: email delivery is not configured (RESEND_API_KEY and RESEND_FROM), so the confirmation was not sent");
            return;
        }
        Err(e) => {
            eprintln!("newsletter: {e}");
            return;
        }
    };
    if !confirmation_cooldown().try_acquire(email) {
        eprintln!("newsletter: a confirmation was already emailed to this address in the last 10 minutes, so none was sent; the subscriber stays pending");
        return;
    }
    let site = site_url();
    let link = confirm_url(&site, email, &confirm_token(&secret, email));
    let unsubscribe = unsubscribe_url(&site, email, &unsubscribe_token(&secret, email));
    let delivery = mailer
        .deliver(&Email { to: email, subject: "Confirm your newsletter subscription", body: &confirmation_body(&link), unsubscribe_url: Some(&unsubscribe) })
        .await;
    if !delivery.ok {
        eprintln!("newsletter: the confirmation email was not delivered: {}", delivery.reason.unwrap_or_default());
    }
}

/// For a subscriber the domain just created as a side effect of something
/// else (a registration that ticked the newsletter box): email the confirm
/// link only when the address is now a pending subscriber. A registrant
/// already confirmed, or unsubscribed, is left alone.
pub(super) async fn send_confirmation_if_pending(email: &str, client: &Mutex<Client>, wasm_path: &Path) {
    let Some(provider) = ir().and_then(newsletter_provider) else {
        return;
    };
    let Ok(read) = dispatch::read(client, wasm_path).await else {
        return;
    };
    let pending = instances_for(&read, &provider.instance_prefix())
        .iter()
        .any(|(id, subscriber)| id == email && subscriber.get("status").and_then(|v| v.as_str()) == Some("pending"));
    if pending {
        send_confirmation(email).await;
    }
}

/// GET /newsletter/subscribers/confirm?email=...&token=... — the token is the
/// signed one the confirmation email carries (`confirm_token`), and must have
/// been minted for this exact address. Without it, or with a wrong or expired
/// one, the route refuses: an address alone no longer confirms anyone.
/// Idempotent — Confirm only dispatches when the subscriber is actually
/// `pending` (its own `given` refuses a second attempt outright), so a guest
/// double-clicking, or a mail client prefetching the link, still lands on the
/// same success response instead of a 422.
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

/// The refusal for an unsubscribe request that does not carry a valid signed
/// token for its own address: 400 with no address, 403 with a missing, wrong,
/// other-address or expired token, or when there is no secret to check against.
/// On success, the address.
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

/// GET /newsletter/subscribers/unsubscribe?email=...&token=... — same shape as
/// newsletter_confirm_route above, and like it the token must be the signed
/// one the emails carry (`unsubscribe_token`), minted for this exact address;
/// anything else is a 403 before any subscriber is looked up. Ported from
/// http_server.rb's own route (that one had no token), ported from http_server.rb's own
/// with the same idempotency reasoning:
/// Unsubscribe's own `given` only accepts a pending or confirmed
/// subscriber, so a repeat click on an already-unsubscribed row would
/// otherwise 422 instead of showing the same success page). This is the
/// one newsletter-unsubscribed.astro's own server-side fetch calls —
/// unreachable before this route existed (confirmed live: fell through
/// to auth_gate's 401, never a 404, since neither this path nor
/// /confirm was in UNGATED_PATHS and nothing recognized either one).
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
