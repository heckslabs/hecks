// The email a registrant gets once their payment has gone through: what they
// booked and what they paid. Best-effort, like every other mail the host
// sends: the payment stands whatever delivery does.

use super::instances_for;
use crate::dispatch;
use crate::ir::PaymentsProvider;
use crate::journal::LineageConfig;
use crate::resend::{Email, Mailer};
use serde_json::{json, Value};
use std::path::Path;
use tokio::sync::Mutex;
use tokio_postgres::Client;

#[cfg(test)]
mod tests;

fn dollars(cents: i64) -> String {
    format!("${}.{:02}", cents / 100, cents % 100)
}

fn receipt_subject(event_name: &str) -> String {
    format!("You're registered for {event_name}")
}

/// The subject and body the site built from the wording an editor keeps in
/// the CMS (when, where and how-to-prepare are filled in there: the venue lives
/// only in the CMS).
#[derive(Debug, PartialEq)]
struct SiteEmail {
    subject: String,
    body: String,
}

fn site_email_from_json(body: &Value) -> Option<SiteEmail> {
    let text = |key: &str| body.get(key).and_then(Value::as_str).filter(|s| !s.trim().is_empty()).map(String::from);
    Some(SiteEmail { subject: text("subject")?, body: text("body")? })
}

/// Asks the site for the finished email (signed, short-lived, bound to this
/// one event). Best effort: any failure means the host's own built-in wording
/// goes out instead, so a receipt is always sent.
async fn site_email(event_slug: &str, first_name: Option<&str>, amount_cents: Option<i64>) -> Option<SiteEmail> {
    let secret = std::env::var("SESSION_SECRET").ok().filter(|s| !s.is_empty())?;
    let token = crate::auth::purpose_token(&secret, "confirmation-email", json!({ "event": event_slug }), 300);
    let mut url = reqwest::Url::parse(&format!("{}/api/confirmation-email", super::newsletter_send::site_url())).ok()?;
    {
        let mut query = url.query_pairs_mut();
        query.append_pair("event", event_slug);
        if let Some(name) = first_name {
            query.append_pair("first_name", name);
        }
        if let Some(cents) = amount_cents {
            query.append_pair("amount_cents", &cents.to_string());
        }
    }
    let response = reqwest::Client::new().get(url).header("x-internal-auth", token).timeout(std::time::Duration::from_secs(8)).send().await.ok()?;
    if !response.status().is_success() {
        return None;
    }
    site_email_from_json(&response.json::<Value>().await.ok()?)
}

/// The host's own wording, used when the site cannot be asked.
fn built_in_body(first_name: Option<&str>, event_name: &str, amount_cents: Option<i64>) -> String {
    let greeting = first_name.map(|name| format!("Hi {name},")).unwrap_or_else(|| "Hi,".to_string());
    let paid = amount_cents.map(|cents| format!(" We received your payment of {}.", dollars(cents))).unwrap_or_default();
    format!("{greeting}\n\nYou're registered for {event_name}.{paid}\n\nYour seat is held. If anything changes, just reply to this email.\n")
}

/// Mails the receipt for `reference` if its Payment has succeeded. A missing
/// mailer, registrant address or event is skipped quietly.
pub(super) async fn send_receipt(reference: &str, client: &Mutex<Client>, wasm_path: &Path, config: &LineageConfig, payments: &PaymentsProvider) {
    let mailer = match Mailer::from_env() {
        Ok(Some(mailer)) => mailer,
        Ok(None) => return,
        Err(e) => {
            eprintln!("registration receipt: {e}");
            return;
        }
    };
    let Ok(read) = dispatch::read(client, wasm_path).await else {
        return;
    };
    let binding = crate::ir::registrations_binding(&config.domain);
    let registrations = instances_for(&read, &binding.registration_prefix());
    let Some((_, registration)) = registrations.iter().find(|(id, _)| id == reference) else {
        return;
    };
    let payment_instances = instances_for(&read, &payments.instance_prefix());
    let payment = payment_instances.iter().find(|(id, _)| id == reference).map(|(_, p)| p);
    if payment.and_then(|p| p.get("status")).and_then(|s| s.as_str()) != Some("succeeded") {
        return;
    }
    let attendee = registration.get("attendee").cloned().unwrap_or_else(|| serde_json::json!({}));
    let Some(to) = attendee.get("email").and_then(|v| v.as_str()).filter(|s| !s.is_empty()) else {
        return;
    };
    let events = instances_for(&read, &binding.event_prefix());
    let event_name = registration
        .get("event_slug")
        .and_then(|v| v.as_str())
        .and_then(|slug| events.iter().find(|(id, _)| id == slug))
        .and_then(|(_, e)| e.get("name"))
        .and_then(|n| n.get("value"))
        .and_then(|v| v.as_str())
        .unwrap_or("your event");
    let amount = payment.and_then(|p| p.get("amount")).and_then(|a| a.get("cents")).and_then(Value::as_i64);
    let first_name = attendee.get("first_name").and_then(|v| v.as_str()).filter(|s| !s.is_empty());
    let from_site = match registration.get("event_slug").and_then(|v| v.as_str()) {
        Some(slug) => site_email(slug, first_name, amount).await,
        None => None,
    };
    let (subject, body) = match from_site {
        Some(email) => (email.subject, email.body),
        None => (receipt_subject(event_name), built_in_body(first_name, event_name, amount)),
    };
    let delivery = mailer.deliver(&Email { to, subject: &subject, body: &body, unsubscribe_url: None }).await;
    if !delivery.ok {
        eprintln!("registration receipt: not delivered: {}", delivery.reason.unwrap_or_default());
    }
}
