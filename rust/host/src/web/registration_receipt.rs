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

fn receipt_body(first_name: Option<&str>, event_name: &str, amount_cents: Option<i64>) -> String {
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
    let delivery = mailer
        .deliver(&Email { to, subject: &receipt_subject(event_name), body: &receipt_body(first_name, event_name, amount), unsubscribe_url: None })
        .await;
    if !delivery.ok {
        eprintln!("registration receipt: not delivered: {}", delivery.reason.unwrap_or_default());
    }
}
