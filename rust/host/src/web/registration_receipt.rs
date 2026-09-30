// The email a registrant gets once their payment has gone through: what they
// booked and what they paid. Best-effort, like every other mail the host
// sends: the payment stands whatever delivery does.

use super::instances_for;
use crate::dispatch;
use crate::ir::PaymentsProvider;
use crate::journal::LineageConfig;
use crate::resend::{Email, Mailer};
use serde_json::Value;
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

/// What the site knows about a session: when it is and where.
#[derive(Debug, Default, PartialEq)]
struct SessionDetails {
    when: Option<String>,
    place: Option<String>,
}

fn session_from_json(body: &Value) -> SessionDetails {
    let text = |key: &str| body.get(key).and_then(Value::as_str).map(str::trim).filter(|s| !s.is_empty()).map(String::from);
    SessionDetails { when: text("when"), place: text("where") }
}

/// Asks the site for the session's date, time and venue (the host knows the
/// date and time labels, but the venue lives in the CMS). Best effort: any
/// failure means the email goes out without those lines.
async fn session_details(event_slug: &str) -> SessionDetails {
    let mut url = match reqwest::Url::parse(&format!("{}/api/session-details", super::newsletter_send::site_url())) {
        Ok(url) => url,
        Err(_) => return SessionDetails::default(),
    };
    url.query_pairs_mut().append_pair("event", event_slug);
    let answer = match reqwest::Client::new().get(url).timeout(std::time::Duration::from_secs(5)).send().await {
        Ok(response) if response.status().is_success() => response.json::<Value>().await.ok(),
        _ => None,
    };
    answer.map(|body| session_from_json(&body)).unwrap_or_default()
}

fn receipt_body(first_name: Option<&str>, event_name: &str, amount_cents: Option<i64>, session: &SessionDetails) -> String {
    let greeting = first_name.map(|name| format!("Hi {name},")).unwrap_or_else(|| "Hi,".to_string());
    let paid = amount_cents.map(|cents| format!(" We received your payment of {}.", dollars(cents))).unwrap_or_default();
    let mut details = Vec::new();
    if let Some(when) = &session.when {
        details.push(format!("When: {when}"));
    }
    if let Some(place) = &session.place {
        details.push(format!("Where: {place}"));
    }
    let details = if details.is_empty() { String::new() } else { format!("{}\n\n", details.join("\n")) };
    format!("{greeting}\n\nYou're registered for {event_name}.{paid}\n\n{details}Your seat is held. If anything changes, just reply to this email.\n")
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
    let session = match registration.get("event_slug").and_then(|v| v.as_str()) {
        Some(slug) => session_details(slug).await,
        None => SessionDetails::default(),
    };
    let delivery = mailer
        .deliver(&Email { to, subject: &receipt_subject(event_name), body: &receipt_body(first_name, event_name, amount, &session), unsubscribe_url: None })
        .await;
    if !delivery.ok {
        eprintln!("registration receipt: not delivered: {}", delivery.reason.unwrap_or_default());
    }
}
