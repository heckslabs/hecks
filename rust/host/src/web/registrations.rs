use super::{instances_for, last_refusal, respond, with_id};
use crate::checkout;
use crate::dispatch;
use crate::commerce_ir::{payments_provider, PaymentsProvider};
use crate::journal::LineageConfig;
use crate::lambda_client::LambdaInvoker;
use crate::payments;
use serde_json::{json, Value};
use std::path::Path;
use tokio::sync::Mutex;
use tokio_postgres::Client;

// Routes for /events, /registrations and /webhooks/stripe. Event and
// Registration names are fixed here rather than read from the IR.

/// Whether checkout is on: `configured` must be set and equal `domain`
/// exactly — a mismatch would dispatch the wrong domain's Registration.Request.
pub fn checkout_enabled(configured: Option<&str>, domain: &str) -> bool {
    configured.is_some_and(|c| !c.is_empty() && c == domain)
}

// Fixed, publicly-known, non-secret mock webhook secret; used only while
// STRIPE_WEBHOOK_SECRET is unset, so a mock deploy needs no secret to be
// exercisable end to end.
pub(crate) const MOCK_STRIPE_WEBHOOK_SECRET: &str = "whsec_mock_checkout_fixed";

// The processor a Payment reports, as Payment.Initiate recorded it. Read off
// the Payment itself, not the connection now in effect — the connection can
// change between a guest registering and the webhook arriving.
fn payment_processor(read: &Value, payments: &PaymentsProvider, reference: &str) -> Option<String> {
    instances_for(read, &payments.instance_prefix())
        .into_iter()
        .find(|(id, _)| id == reference)
        .and_then(|(_, payment)| payment.get("processor").and_then(|p| p.get("value")).and_then(|v| v.as_str()).map(String::from))
}

// Payment statuses whose registration still holds a seat come from the
// payment lifecycle's `holds_seat` mark (`PaymentsProvider::holds_seat`). A
// registration with no Payment, or one that's archived, holds none.

/// The Registration lifecycle state that gives its seat back.
const ARCHIVED_REGISTRATION_STATUS: &str = "archived";

/// Whether a registration's own lifecycle has archived it. A missing or
/// non-text `status` is active.
fn registration_archived(registration: &Value) -> bool {
    registration.get("status").and_then(|s| s.as_str()) == Some(ARCHIVED_REGISTRATION_STATUS)
}

/// A reference to an aggregate reads back as its plain id, or wrapped as
/// `{"value": id}`; an empty id is no reference.
fn plain_id(raw: Option<&Value>) -> Option<String> {
    let raw = raw?;
    let value = raw.get("value").unwrap_or(raw);
    value.as_str().filter(|id| !id.is_empty()).map(String::from)
}

/// Seats used per event slug: non-archived Registrations whose Payment (same
/// reference) is in a seat-holding status.
fn seat_counts(read: &Value, domain: &str, payments: &PaymentsProvider) -> std::collections::HashMap<String, usize> {
    let statuses: std::collections::HashMap<String, String> = instances_for(read, &payments.instance_prefix())
        .into_iter()
        .filter_map(|(id, payment)| payment.get("status").and_then(|s| s.as_str()).map(|s| (id, s.to_string())))
        .collect();
    let mut counts = std::collections::HashMap::new();
    for (id, registration) in instances_for(read, &crate::commerce_ir::registrations_binding(domain).registration_prefix()) {
        let holds = statuses.get(&id).is_some_and(|status| payments.holds_seat.iter().any(|held| held == status));
        if let (true, false, Some(event_slug)) = (holds, registration_archived(&registration), plain_id(registration.get("event_slug"))) {
            *counts.entry(event_slug).or_insert(0) += 1;
        }
    }
    counts
}

/// How many seats one event has used.
pub(crate) fn seats_taken(read: &Value, domain: &str, payments: &PaymentsProvider, event_slug: &str) -> usize {
    seat_counts(read, domain, payments).get(event_slug).copied().unwrap_or(0)
}

/// An event's capacity, when it carries a readable one.
fn event_capacity(event: &Value) -> Option<i64> {
    event.get("capacity").and_then(|c| c.get("value")).and_then(|v| v.as_i64())
}

/// Seats still open given `taken`, never below zero.
fn open_seats(capacity: i64, taken: usize) -> i64 {
    (capacity - taken as i64).max(0)
}

/// Seats still open on one event, never below zero; `None` when there is no
/// such event or it carries no readable capacity.
pub(crate) fn seats_left(read: &Value, domain: &str, payments: &PaymentsProvider, event_slug: &str) -> Option<i64> {
    let events = instances_for(read, &crate::commerce_ir::registrations_binding(domain).event_prefix());
    let (_, event) = events.iter().find(|(id, _)| id == event_slug)?;
    Some(open_seats(event_capacity(event)?, seats_taken(read, domain, payments, event_slug)))
}

/// The seat figures a caller reads for one event: `capacity` and `seats_left`
/// are `null` when the event carries no readable capacity.
fn seat_figures(event: &Value, taken: usize) -> Value {
    let capacity = event_capacity(event);
    json!({"capacity": capacity, "seats_taken": taken, "seats_left": capacity.map(|c| open_seats(c, taken))})
}

/// The seat figures of every event, keyed by event slug.
fn all_seat_figures(read: &Value, domain: &str, payments: &PaymentsProvider) -> Value {
    let counts = seat_counts(read, domain, payments);
    let events = instances_for(read, &crate::commerce_ir::registrations_binding(domain).event_prefix());
    let figures: serde_json::Map<String, Value> =
        events.iter().map(|(slug, event)| (slug.clone(), seat_figures(event, counts.get(slug).copied().unwrap_or(0)))).collect();
    json!({"events": figures})
}

/// The seat figures of one event, with its `slug`; `None` when there is no such event.
fn one_seat_figures(read: &Value, domain: &str, payments: &PaymentsProvider, event_slug: &str) -> Option<Value> {
    let events = instances_for(read, &crate::commerce_ir::registrations_binding(domain).event_prefix());
    let (_, event) = events.iter().find(|(id, _)| id == event_slug)?;
    let mut figures = seat_figures(event, seats_taken(read, domain, payments, event_slug));
    figures["slug"] = json!(event_slug);
    Some(figures)
}

/// The slug in `/events/<slug>/seats`; a slug is one non-empty path segment.
fn seats_path_slug(path: &str) -> Option<&str> {
    let slug = path.strip_prefix("/events/")?.strip_suffix("/seats")?;
    (!slug.is_empty() && !slug.contains('/')).then_some(slug)
}

/// GET /events/seats and GET /events/<slug>/seats: the seat rule as a read,
/// so a site never has to count registrations itself.
async fn seats_route(path: &str, client: &Mutex<Client>, wasm_path: &Path, config: &LineageConfig, payments: &PaymentsProvider) -> Value {
    let read = match dispatch::read(client, wasm_path).await {
        Ok(r) => r,
        Err(e) => return respond(500, "text/plain", &format!("{e:#}")),
    };
    let body = match seats_path_slug(path) {
        None => all_seat_figures(&read, &config.domain, payments),
        Some(slug) => match one_seat_figures(&read, &config.domain, payments, slug) {
            Some(figures) => figures,
            None => return respond(404, "application/json", &json!({"error": "no such event"}).to_string()),
        },
    };
    respond(200, "application/json", &body.to_string())
}

fn unix_now() -> i64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_secs() as i64
}

#[allow(clippy::too_many_arguments)]
// Serves the checkout, registration-payment and webhook routes only when the
// domain's IR declares `provides "payments"`. Takes the IR as a parameter,
// not `ir()`, so the gate can be tested against one that lacks the key.
#[allow(clippy::too_many_arguments)]
pub(super) async fn payments_routes(
    domain_ir: Option<&Value>,
    method: &str,
    path: &str,
    raw_body: &str,
    stripe_signature: &str,
    client: &Mutex<Client>,
    wasm_path: &Path,
    config: &LineageConfig,
    invoker: &dyn LambdaInvoker,
) -> Option<Value> {
    let payments = domain_ir.and_then(payments_provider)?;
    checkout_route(method, path, raw_body, stripe_signature, client, wasm_path, config, invoker, &payments).await
}

pub(super) async fn checkout_route(
    method: &str,
    path: &str,
    raw_body: &str,
    stripe_signature: &str,
    client: &Mutex<Client>,
    wasm_path: &Path,
    config: &LineageConfig,
    invoker: &dyn LambdaInvoker,
    payments: &PaymentsProvider,
) -> Option<Value> {
    match (method, path) {
        ("POST", "/registrations") => {
            Some(registrations_route(raw_body, &payments::PlatformConfig::load().await, client, wasm_path, config, invoker, payments).await)
        }
        // GET /registrations/:id: read-only, re-derives state server-side
        // for the confirmation and pay pages rather than trusting their own
        // query string.
        ("GET", path) if path.starts_with("/registrations/") && !path.ends_with("/complete") => {
            let registration_id = path.trim_start_matches("/registrations/");
            Some(registration_show_route(registration_id, client, wasm_path, config, payments).await)
        }
        // POST /registrations/:id/complete: mock checkout's Pay/Cancel button,
        // refused unless the Payment's own processor is "mock_stripe". Settles
        // through the same PaymentGateway port as POST /webhooks/stripe.
        ("POST", path) if path.starts_with("/registrations/") && path.ends_with("/complete") => {
            let registration_id = path.trim_start_matches("/registrations/").trim_end_matches("/complete").trim_end_matches('/');
            Some(registration_complete_route(registration_id, raw_body, client, wasm_path, config, invoker, payments).await)
        }
        ("POST", "/webhooks/stripe") => {
            Some(webhook_route(raw_body, stripe_signature, &payments::PlatformConfig::load().await, client, wasm_path, config, invoker, payments).await)
        }
        // POST /events: a mock-payments service schedules a new session
        // when an editor picks a date. Idempotent — Event.find first means
        // a repeat call for the same slug is a no-op, not an error.
        ("GET", "/events/seats") => Some(seats_route(path, client, wasm_path, config, payments).await),
        ("GET", path) if seats_path_slug(path).is_some() => Some(seats_route(path, client, wasm_path, config, payments).await),
        ("POST", "/events") => Some(events_route(raw_body, client, wasm_path, config, invoker).await),
        _ => None,
    }
}

/// POST /events. Dispatches `<domain>::Event.Schedule` — Event is this
/// deploy's own top-level aggregate, not a vendored chapter like Payments.
async fn events_route(raw_body: &str, client: &Mutex<Client>, wasm_path: &Path, config: &LineageConfig, invoker: &dyn LambdaInvoker) -> Value {
    let body: Value = match serde_json::from_str(raw_body) {
        Ok(v) => v,
        Err(e) => return respond(400, "application/json", &json!({"error": format!("invalid JSON: {e}")}).to_string()),
    };
    let Some(slug) = body.get("slug").and_then(|v| v.as_str()) else {
        return respond(400, "application/json", &json!({"error": "missing slug"}).to_string());
    };

    let read = match dispatch::read(client, wasm_path).await {
        Ok(r) => r,
        Err(e) => return respond(500, "text/plain", &format!("{e:#}")),
    };
    let events = instances_for(&read, &crate::commerce_ir::registrations_binding(&config.domain).event_prefix());
    if let Some((_, existing)) = events.iter().find(|(id, _)| id == slug) {
        return respond(200, "application/json", &serde_json::to_string_pretty(&with_id(slug, existing)).unwrap_or_default());
    }

    let Some(name) = body.get("name").and_then(|v| v.as_str()) else {
        return respond(400, "application/json", &json!({"error": "missing name"}).to_string());
    };
    let Some(price_cents) = body.get("price_cents").and_then(|v| v.as_i64()) else {
        return respond(400, "application/json", &json!({"error": "missing price_cents"}).to_string());
    };
    let Some(capacity) = body.get("capacity").and_then(|v| v.as_i64()) else {
        return respond(400, "application/json", &json!({"error": "missing capacity"}).to_string());
    };

    let args = json!({
        "slug": {"value": slug},
        "name": {"value": name},
        "price": {"cents": price_cents},
        "capacity": {"value": capacity},
    });
    let verb = crate::commerce_ir::registrations_binding(&config.domain).schedule;
    let outcome = match dispatch::handle(client, wasm_path, &verb, args, None, config, invoker).await {
        Ok(o) => o,
        Err(e) => return respond(500, "text/plain", &format!("{e:#}")),
    };
    if !outcome.accepted {
        return respond(422, "application/json", &last_refusal(&outcome.result).to_string());
    }

    let read = match dispatch::read(client, wasm_path).await {
        Ok(r) => r,
        Err(e) => return respond(500, "text/plain", &format!("{e:#}")),
    };
    let events = instances_for(&read, &crate::commerce_ir::registrations_binding(&config.domain).event_prefix());
    let Some((_, event)) = events.iter().find(|(id, _)| id == slug) else {
        return respond(500, "text/plain", "event vanished immediately after being scheduled");
    };
    respond(201, "application/json", &serde_json::to_string_pretty(&with_id(slug, event)).unwrap_or_default())
}

/// GET /registrations/:id: event and attendee fields, plus amount_cents and
/// payment_status from the same-reference Payment.
async fn registration_show_route(registration_id: &str, client: &Mutex<Client>, wasm_path: &Path, config: &LineageConfig, payments: &PaymentsProvider) -> Value {
    let read = match dispatch::read(client, wasm_path).await {
        Ok(r) => r,
        Err(e) => return respond(500, "text/plain", &format!("{e:#}")),
    };
    let registrations = instances_for(&read, &crate::commerce_ir::registrations_binding(&config.domain).registration_prefix());
    let Some((_, registration)) = registrations.iter().find(|(id, _)| id == registration_id) else {
        return respond(404, "application/json", &json!({"error": "no such registration"}).to_string());
    };
    let event_slug = registration.get("event_slug").and_then(|v| v.as_str());
    let events = instances_for(&read, &crate::commerce_ir::registrations_binding(&config.domain).event_prefix());
    let event = event_slug.and_then(|slug| events.iter().find(|(id, _)| id == slug)).map(|(_, e)| e);

    let payment_instances = instances_for(&read, &payments.instance_prefix());
    let payment = payment_instances.iter().find(|(id, _)| id == registration_id).map(|(_, p)| p);

    let attendee = registration.get("attendee").cloned().unwrap_or_else(|| json!({}));
    respond(200, "application/json", &json!({
        "registration_id": registration_id,
        "event": {
            "slug": event_slug,
            "name": event.and_then(|e| e.get("name")).and_then(|n| n.get("value")).and_then(|v| v.as_str()),
        },
        "attendee": {
            "first_name": attendee.get("first_name"),
            "last_name": attendee.get("last_name"),
            "email": attendee.get("email"),
            "phone": attendee.get("phone"),
        },
        "amount_cents": payment.and_then(|p| p.get("amount")).and_then(|a| a.get("cents")),
        "payment_status": payment.and_then(|p| p.get("status")),
    }).to_string())
}

/// POST /registrations/:id/complete. Refused unless the Payment itself was
/// initiated on "mock_stripe"; settles through the same PaymentGateway port webhook_route uses.
pub(crate) async fn registration_complete_route(
    registration_id: &str,
    raw_body: &str,
    client: &Mutex<Client>,
    wasm_path: &Path,
    config: &LineageConfig,
    invoker: &dyn LambdaInvoker,
    payments: &PaymentsProvider,
) -> Value {
    let body: Value = match serde_json::from_str(raw_body) {
        Ok(v) => v,
        Err(e) => return respond(400, "application/json", &json!({"error": format!("invalid JSON: {e}")}).to_string()),
    };
    let Some(outcome) = body.get("outcome").and_then(|v| v.as_str()) else {
        return respond(400, "application/json", &json!({"error": "missing outcome"}).to_string());
    };
    if outcome != "succeeded" && outcome != "failed" {
        return respond(400, "application/json", &json!({"error": "outcome must be \"succeeded\" or \"failed\""}).to_string());
    }

    let read = match dispatch::read(client, wasm_path).await {
        Ok(r) => r,
        Err(e) => return respond(500, "text/plain", &format!("{e:#}")),
    };
    let registrations = instances_for(&read, &crate::commerce_ir::registrations_binding(&config.domain).registration_prefix());
    if !registrations.iter().any(|(id, _)| id == registration_id) {
        return respond(404, "application/json", &json!({"error": "no such registration"}).to_string());
    }

    let processor = match payment_processor(&read, payments, registration_id) {
        Some(processor) if processor == "mock_stripe" => processor,
        _ => return respond(403, "application/json", &json!({"error": "not available with a real payment processor"}).to_string()),
    };
    let reported_processor = json!({"value": processor});
    // `reference_to Payment, as: :reference` keeps `reference` inside `with:`
    // too — `to:` alone isn't enough, the argument parser still expects it
    // present in facts or it TypeMismatches.
    let reference_fact = json!({"value": registration_id});
    let (verb, facts) = if outcome == "succeeded" {
        (
            payments.succeeded.as_str(),
            json!({"reference": reference_fact, "transaction_id": {"value": format!("local_{}", uuid::Uuid::new_v4().simple())}, "reported_processor": reported_processor}),
        )
    } else {
        (
            payments.failed.as_str(),
            json!({"reference": reference_fact, "reason": {"value": "declined_at_local_checkout"}, "reported_processor": reported_processor}),
        )
    };
    let outcome_result = match dispatch::handle_routed(client, wasm_path, verb, json!(registration_id), facts, None, config, invoker).await {
        Ok(o) => o,
        Err(e) => return respond(500, "text/plain", &format!("{e:#}")),
    };
    // A repeat Succeeded/Failed on an already-settled Payment is a silent
    // no-op on Payment's own `given`, so it isn't surfaced as a 422 here
    // either.
    if !outcome_result.accepted {
        let refusal = last_refusal(&outcome_result.result);
        let already_settled = refusal.get("error").and_then(|v| v.as_str()).map(|s| s.contains("pending")).unwrap_or(false);
        if !already_settled {
            return respond(422, "application/json", &refusal.to_string());
        }
    }

    // Only a payment that settled just now earns a receipt; a repeat click was
    // refused above as already settled.
    if outcome == "succeeded" && outcome_result.accepted {
        super::registration_receipt::send_receipt(registration_id, client, wasm_path, config, payments).await;
    }

    let read = match dispatch::read(client, wasm_path).await {
        Ok(r) => r,
        Err(e) => return respond(500, "text/plain", &format!("{e:#}")),
    };
    let payment_instances = instances_for(&read, &payments.instance_prefix());
    let status = payment_instances.iter().find(|(id, _)| id == registration_id).and_then(|(_, p)| p.get("status")).and_then(|v| v.as_str()).unwrap_or("");
    respond(200, "application/json", &json!({"registration_id": registration_id, "payment_status": status}).to_string())
}

// Attendee shape varies per domain, so this forwards the caller's fields
// through verbatim rather than hardcoding one shape; each domain's own
// given/invariant checks remain the real validation. Only `event_slug` and
// `return_to` (routing metadata, never part of Attendee) are stripped.
fn attendee_from(body: &Value) -> Value {
    let mut attendee = body.clone();
    if let Some(object) = attendee.as_object_mut() {
        object.remove("event_slug");
        object.remove("return_to");
    }
    attendee
}

// Payment's own Client value object wants a single `name`, so a caller
// sending `first_name`/`last_name` instead gets a composed display name
// rather than this route hardcoding one shape.
fn display_name_from(body: &Value) -> Option<String> {
    if let Some(name) = body.get("name").and_then(|v| v.as_str()) {
        return Some(name.to_string());
    }
    let first = body.get("first_name").and_then(|v| v.as_str())?;
    let last = body.get("last_name").and_then(|v| v.as_str())?;
    Some(format!("{first} {last}"))
}

// POST /registrations. Payment first, then Registration, sharing one
// reference minted here; `role: None` throughout since the site calls in
// server-to-server, not as a signed-in user.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn registrations_route(
    raw_body: &str,
    platform: &payments::PlatformConfig,
    client: &Mutex<Client>,
    wasm_path: &Path,
    config: &LineageConfig,
    invoker: &dyn LambdaInvoker,
    payments: &PaymentsProvider,
) -> Value {
    let body: Value = match serde_json::from_str(raw_body) {
        Ok(v) => v,
        Err(e) => return respond(400, "application/json", &json!({"error": format!("invalid JSON: {e}")}).to_string()),
    };
    let Some(event_slug) = body.get("event_slug").and_then(|v| v.as_str()) else {
        return respond(400, "application/json", &json!({"error": "missing event_slug"}).to_string());
    };
    // Cheap early exits before dispatching Payment.Initiate — full Attendee
    // validation still happens downstream in Registration.Request's own
    // given/invariant checks.
    let Some(name) = display_name_from(&body) else {
        return respond(400, "application/json", &json!({"error": "missing name (or first_name and last_name)"}).to_string());
    };
    let Some(email) = body.get("email").and_then(|v| v.as_str()) else {
        return respond(400, "application/json", &json!({"error": "missing email"}).to_string());
    };

    let read = match dispatch::read(client, wasm_path).await {
        Ok(r) => r,
        Err(e) => return respond(500, "text/plain", &format!("{e:#}")),
    };
    let events = instances_for(&read, &crate::commerce_ir::registrations_binding(&config.domain).event_prefix());
    let Some((_, event)) = events.iter().find(|(id, _)| id == event_slug) else {
        return respond(404, "application/json", &json!({"error": "no such event"}).to_string());
    };
    if event.get("status").and_then(|v| v.as_str()) != Some("open") {
        return respond(422, "application/json", &json!({"error": "registration is closed for this event"}).to_string());
    }
    // A full event refuses before any Stripe call or write. An event whose
    // capacity cannot be read is not blocked: capacity is required when an
    // event is scheduled, so its absence means nothing to enforce.
    if seats_left(&read, &config.domain, payments, event_slug) == Some(0) {
        return respond(409, "application/json", &json!({"error": "this event is full"}).to_string());
    }
    let price_cents = event.get("price").and_then(|p| p.get("cents")).and_then(|v| v.as_i64()).unwrap_or(0);
    let event_name = event.get("name").and_then(|n| n.get("value")).and_then(|v| v.as_str()).unwrap_or("");

    // What checkout does is decided per request from this tenant's own
    // PaymentConnection, before anything is written — a paused connection
    // must never fall back to the mock walkthrough.
    let plan = payments::checkout_plan(payments::connection(&read, &config.domain).as_ref(), platform);
    let processor = match plan {
        payments::CheckoutPlan::Mock => "mock_stripe",
        payments::CheckoutPlan::Stripe { .. } => "stripe",
        payments::CheckoutPlan::Paused => {
            return respond(503, "application/json", &json!({"error": "payments are temporarily unavailable"}).to_string());
        }
    };
    let site_url = platform.site_url.as_str();

    let reference = uuid::Uuid::new_v4().to_string();

    // A Stripe plan opens its embedded session before anything is written, so
    // a failure leaves no Payment or Registration behind. If a domain refusal
    // follows, the unused session simply expires.
    let embedded_checkout = if let payments::CheckoutPlan::Stripe { api_key, publishable_key } = &plan {
        let auth = checkout::StripeAuth { api_key, base_url: &platform.api_base };
        match checkout::create_checkout_session(&auth, price_cents, event_name, &reference, checkout::session_expires_at(unix_now())).await {
            // Stripe.js is opened with the publishable key; the answer carries
            // no `checkout_url`.
            Ok(session) => Some(json!({
                "client_secret": session.client_secret,
                "publishable_key": publishable_key,
                "session_id": session.session_id,
            })),
            Err(e) => {
                eprintln!("registrations: opening the Stripe session failed, nothing was recorded: {e:#}");
                return respond(502, "application/json", &json!({"error": "payments are temporarily unavailable"}).to_string());
            }
        }
    } else {
        None
    };

    let initiate_args = json!({
        "reference": {"value": reference},
        "processor": {"value": processor},
        "payment_type": {"value": "card"},
        "amount": {"cents": price_cents},
        "client": {"name": name, "email": email},
    });
    let outcome = match dispatch::handle(client, wasm_path, &payments.initiate, initiate_args, None, config, invoker).await {
        Ok(o) => o,
        Err(e) => return respond(500, "text/plain", &format!("{e:#}")),
    };
    if !outcome.accepted {
        return respond(422, "application/json", &last_refusal(&outcome.result).to_string());
    }

    let mut request_args = json!({
        "event_slug": event_slug,
        "registration_id": {"value": reference},
        "attendee": attendee_from(&body),
    });
    // A reaction reads only fields its event carries, never ones nested
    // inside `attendee`, so newsletter fields are declared flat on
    // Registration.Request; a command refuses args it doesn't declare.
    let news_signup = body.get("news_signup").and_then(|v| v.as_bool()).unwrap_or(false);
    let binding = crate::commerce_ir::registrations_binding(&config.domain);
    let forwards_newsletter = crate::ir::ir().is_some_and(|ir| {
        binding.request_target().is_some_and(|(aggregate, command)| crate::commerce_ir::command_declares(ir, aggregate, command, "news_signup"))
    });
    if forwards_newsletter {
        request_args["news_signup"] = json!(news_signup);
        request_args["email"] = json!(email);
        for field in ["first_name", "last_name"] {
            if let Some(value) = body.get(field) {
                request_args[field] = value.clone();
            }
        }
    }
    let request_verb = crate::commerce_ir::registrations_binding(&config.domain).request;
    let outcome = match dispatch::handle(client, wasm_path, &request_verb, request_args, None, config, invoker).await {
        Ok(o) => o,
        Err(e) => return respond(500, "text/plain", &format!("{e:#}")),
    };
    if !outcome.accepted {
        return respond(422, "application/json", &last_refusal(&outcome.result).to_string());
    }

    // The domain's reaction has already subscribed the address by now; a
    // registrant who ticked the box gets the same signed confirm link as the
    // footer form. Best effort: the registration stands whatever mail does.
    if forwards_newsletter && news_signup {
        super::newsletter::send_confirmation_if_pending(email, client, wasm_path).await;
    }

    if let Some(embedded) = embedded_checkout {
        return respond(200, "application/json", &json!({"registration_id": reference, "embedded_checkout": embedded}).to_string());
    }

    // `return_to` is guest-supplied and never trusted raw — only a same-site
    // path (one leading slash, not two) is kept, since e.g. "//evil.example"
    // would otherwise be an open redirect; anything else falls back to "/".
    let return_to = match body.get("return_to").and_then(|v| v.as_str()) {
        Some(path) if path.starts_with('/') && !path.starts_with("//") => path.to_string(),
        _ => "/".to_string(),
    };
    let confirm_query = |outcome: &str| -> String {
        let mut url = reqwest::Url::parse("http://placeholder.invalid/").unwrap();
        url.query_pairs_mut()
            .append_pair("registration_id", &reference)
            .append_pair("outcome", outcome)
            .append_pair("return_to", &return_to);
        url.query().unwrap_or("").to_string()
    };
    let success_url = format!("{site_url}/registration-confirmed.html?{}", confirm_query("succeeded"));
    let cancel_url = format!("{site_url}/registration-confirmed.html?{}", confirm_query("cancelled"));

    // A tenant with no connection, or a disabled one, is on the mock
    // walkthrough, never a misconfiguration to refuse. success_url/cancel_url
    // belong to this walkthrough only — an embedded session redirects nowhere.
    let checkout_url = checkout::mock_checkout_session(&reference, &success_url, &cancel_url, site_url);
    respond(200, "application/json", &json!({"checkout_url": checkout_url, "registration_id": reference}).to_string())
}

// The answer for an event that only the public mock secret could vouch for.
fn mock_secret_refused() -> Value {
    respond(
        500,
        "application/json",
        &json!({"error": "STRIPE_WEBHOOK_SECRET is required to accept events from a real payment processor -- \
                          refusing to trust the publicly-known mock webhook secret"})
        .to_string(),
    )
}

/// POST /webhooks/stripe. Verifies the signature against
/// `STRIPE_WEBHOOK_SECRET`, a saved signing secret, or — only while neither
/// is set — the public mock secret, refusing anything only a real processor
/// could have sent.
pub(crate) async fn webhook_route(
    raw_body: &str,
    signature_header: &str,
    platform: &payments::PlatformConfig,
    client: &Mutex<Client>,
    wasm_path: &Path,
    config: &LineageConfig,
    invoker: &dyn LambdaInvoker,
    payments: &PaymentsProvider,
) -> Value {
    let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_secs() as i64;
    // The environment's signing secret and any saved with the business's own
    // keys are all accepted; with none configured only the mock secret is.
    let configured = platform.webhook_secrets();
    if configured.is_empty() && platform.has_real_credentials() {
        // A real key with no signing secret to check events against: the public
        // mock secret must not stand in for it.
        return mock_secret_refused();
    }
    let candidates = if configured.is_empty() { vec![MOCK_STRIPE_WEBHOOK_SECRET] } else { configured };
    let mut verification = Ok(());
    for secret in &candidates {
        verification = checkout::verify_signature(raw_body, signature_header, secret, now);
        if verification.is_ok() {
            break;
        }
    }
    if let Err(e) = verification {
        return respond(400, "text/plain", &e.to_string());
    }
    let event: Value = match serde_json::from_str(raw_body) {
        Ok(v) => v,
        Err(_) => return respond(400, "text/plain", "invalid JSON"),
    };

    let read = match dispatch::read(client, wasm_path).await {
        Ok(r) => r,
        Err(e) => return respond(500, "text/plain", &format!("{e:#}")),
    };
    // The business's own endpoint delivers events with no `account`; one that
    // names an account is some other account's, acknowledged and ignored.
    if event.get("account").and_then(|v| v.as_str()).is_some() {
        return respond(200, "text/plain", "");
    }
    let fallback_secret = platform.webhook_secrets().is_empty();
    let refuse_fallback = mock_secret_refused;

    let event_type = event.get("type").and_then(|v| v.as_str()).unwrap_or("");
    let object = event.get("data").and_then(|d| d.get("object")).cloned().unwrap_or_else(|| json!({}));
    let reference = object.get("metadata").and_then(|m| m.get("registration_id")).and_then(|v| v.as_str()).map(String::from);

    if let Some(reference) = reference {
        // Defaults to "stripe" when there's no matching Payment.
        let processor = payment_processor(&read, payments, &reference).unwrap_or_else(|| "stripe".to_string());
        if fallback_secret && processor != "mock_stripe" {
            return refuse_fallback();
        }
        let reported_processor = json!({"value": processor});
        // The kernel refuses a flat `{"reference": ...}` for an
        // aggregate-scoped port operation — `to` is the bare reference
        // string, and `reference` stays inside `with:` too, since the
        // argument parser still expects to find it in facts.
        let reference_fact = json!({"value": reference.clone()});
        let verb_and_facts = match event_type {
            "checkout.session.completed" => {
                // The PaymentIntent id when one exists, else the Checkout
                // Session's own id — `.get`, not a panic, since a synthetic
                // test payload carries no payment_intent at all.
                let transaction_id = object.get("payment_intent").and_then(|v| v.as_str())
                    .or_else(|| object.get("id").and_then(|v| v.as_str()))
                    .unwrap_or("")
                    .to_string();
                Some((payments.succeeded.as_str(), json!({
                    "reference": reference_fact,
                    "transaction_id": {"value": transaction_id},
                    "reported_processor": reported_processor,
                })))
            }
            "checkout.session.expired" => Some((payments.failed.as_str(), json!({
                "reference": reference_fact,
                "reason": {"value": "checkout_expired"},
                "reported_processor": reported_processor,
            }))),
            _ => None,
        };

        if let Some((verb, facts)) = verb_and_facts {
            // A refusal here (e.g. a redelivered webhook — Stripe's delivery
            // is at-least-once) is a benign no-op: the payment already holds
            // the right status, and 200 tells Stripe's retry logic to stop.
            match dispatch::handle_routed(client, wasm_path, verb, json!(reference), facts, None, config, invoker).await {
                Err(e) => return respond(500, "text/plain", &format!("{e:#}")),
                // Only the delivery that settles the payment sends the receipt;
                // a redelivery is refused and stays quiet.
                Ok(settled) if settled.accepted && event_type == "checkout.session.completed" => {
                    super::registration_receipt::send_receipt(&reference, client, wasm_path, config, payments).await;
                }
                Ok(_) => {}
            }
        }
    }

    respond(200, "text/plain", "")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::lambda_client;
    use crate::web::tests::{provision_lineage, scratch_db};

    fn checkout_config(era: i32) -> LineageConfig {
        LineageConfig { domain: "CheckoutFixture".to_string(), era: Some(era), mirrored: None }
    }

    fn checkout_wasm_path() -> std::path::PathBuf {
        std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../dist/checkout_fixture.wasm")
    }

    async fn schedule_event(client: &Mutex<Client>, wasm_path: &Path, config: &LineageConfig, slug: &str, price_cents: i64) {
        let args = json!({
            "slug": {"value": slug}, "name": {"value": "Sample Studio"},
            "price": {"cents": price_cents}, "capacity": {"value": 20},
        });
        let outcome = dispatch::handle(client, wasm_path, "CheckoutFixture::Event.Schedule", args, None, config, &lambda_client::NeverInvoker)
            .await
            .unwrap();
        assert!(outcome.accepted, "scheduling the fixture event should succeed: {:?}", outcome.result);
    }

    fn sign_stripe_header(secret: &str, now: i64, payload: &str) -> String {
        use hmac::{Hmac, Mac};
        use sha2::Sha256;
        let mut mac = Hmac::<Sha256>::new_from_slice(secret.as_bytes()).unwrap();
        mac.update(format!("{now}.{payload}").as_bytes());
        format!("t={now},v1={}", mac.finalize().into_bytes().iter().map(|b| format!("{b:02x}")).collect::<String>())
    }

    fn now_secs() -> i64 {
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs() as i64
    }

    // A read of the domain: one `yoga` event of `capacity` seats, one `other`
    // event, and a Registration plus same-reference Payment per row, each as
    // (reference, event slug, payment status).
    fn read_with(capacity: i64, rows: &[(&str, &str, &str)]) -> Value {
        let mut instances = serde_json::Map::new();
        instances.insert("CheckoutFixture::Event#yoga".into(), json!({"capacity": {"value": capacity}}));
        instances.insert("CheckoutFixture::Event#other".into(), json!({"capacity": {"value": 5}}));
        for (reference, event, status) in rows {
            instances.insert(format!("CheckoutFixture::Registration#{reference}"), json!({"event_slug": event}));
            instances.insert(format!("Payments::Payment#{reference}"), json!({"status": status}));
        }
        json!({"instances": instances})
    }

    #[test]
    fn a_registration_holds_a_seat_while_its_payment_is_open_paid_or_being_settled() {
        let payments = four_state_payments();
        let read = read_with(
            10,
            &[("a", "yoga", "pending"), ("b", "yoga", "succeeded"), ("c", "yoga", "refunding"), ("d", "yoga", "disputed")],
        );
        assert_eq!(seats_taken(&read, "CheckoutFixture", &payments, "yoga"), 4);
        assert_eq!(seats_left(&read, "CheckoutFixture", &payments, "yoga"), Some(6));
    }

    #[test]
    fn a_failed_refunded_or_charged_back_payment_gives_its_seat_back() {
        let payments = crate::commerce_ir::fixture_payments();
        let read = read_with(
            3,
            &[("a", "yoga", "failed"), ("b", "yoga", "refunded"), ("c", "yoga", "charged_back"), ("d", "yoga", "succeeded")],
        );
        assert_eq!(seats_taken(&read, "CheckoutFixture", &payments, "yoga"), 1);
        assert_eq!(seats_left(&read, "CheckoutFixture", &payments, "yoga"), Some(2));
    }

    #[test]
    fn seats_are_counted_per_event_and_a_registration_without_a_payment_holds_none() {
        let payments = crate::commerce_ir::fixture_payments();
        let mut read = read_with(4, &[("a", "yoga", "succeeded"), ("b", "other", "succeeded")]);
        read["instances"]["CheckoutFixture::Registration#orphan"] = json!({"event_slug": "yoga"});
        assert_eq!(seats_taken(&read, "CheckoutFixture", &payments, "yoga"), 1, "only this event's registrations, and only those with a payment");
        assert_eq!(seats_taken(&read, "CheckoutFixture", &payments, "other"), 1);
    }

    #[test]
    fn an_archived_registration_gives_its_seat_back_whatever_its_payment_says() {
        let payments = crate::commerce_ir::fixture_payments();
        let mut read = read_with(3, &[("a", "yoga", "succeeded"), ("b", "yoga", "pending"), ("c", "yoga", "succeeded")]);
        assert_eq!(seats_taken(&read, "CheckoutFixture", &payments, "yoga"), 3);
        read["instances"]["CheckoutFixture::Registration#a"]["status"] = json!("archived");
        assert_eq!(seats_taken(&read, "CheckoutFixture", &payments, "yoga"), 2, "a paid but archived registration frees its seat");
        assert_eq!(seats_left(&read, "CheckoutFixture", &payments, "yoga"), Some(1));
    }

    #[test]
    fn a_registration_with_no_status_counts_as_active() {
        let payments = crate::commerce_ir::fixture_payments();
        let mut read = read_with(5, &[("a", "yoga", "succeeded"), ("b", "yoga", "succeeded")]);
        // `a` carries no status at all (a domain without the lifecycle, or data
        // from before it existed); `b` says it is active.
        read["instances"]["CheckoutFixture::Registration#b"]["status"] = json!("active");
        assert_eq!(seats_taken(&read, "CheckoutFixture", &payments, "yoga"), 2);
        read["instances"]["CheckoutFixture::Registration#a"]["status"] = json!(null);
        assert_eq!(seats_taken(&read, "CheckoutFixture", &payments, "yoga"), 2, "a null status is not archived either");
    }

    #[test]
    fn a_restored_registration_takes_its_seat_back() {
        let payments = crate::commerce_ir::fixture_payments();
        let mut read = read_with(2, &[("a", "yoga", "succeeded")]);
        read["instances"]["CheckoutFixture::Registration#a"]["status"] = json!("archived");
        assert_eq!(seats_left(&read, "CheckoutFixture", &payments, "yoga"), Some(2));
        read["instances"]["CheckoutFixture::Registration#a"]["status"] = json!("active");
        assert_eq!(seats_left(&read, "CheckoutFixture", &payments, "yoga"), Some(1));
    }

    #[test]
    fn seats_left_with_mixed_statuses_counts_only_the_active_holders() {
        let payments = crate::commerce_ir::fixture_payments();
        let mut read = read_with(
            6,
            &[("a", "yoga", "succeeded"), ("b", "yoga", "succeeded"), ("c", "yoga", "pending"), ("d", "yoga", "failed"), ("e", "other", "succeeded")],
        );
        read["instances"]["CheckoutFixture::Registration#a"]["status"] = json!("archived");
        read["instances"]["CheckoutFixture::Registration#b"]["status"] = json!("active");
        read["instances"]["CheckoutFixture::Registration#d"]["status"] = json!("active");
        read["instances"]["CheckoutFixture::Registration#e"]["status"] = json!("archived");
        // b (active, paid) and c (no status, pending) hold; a is archived, d's
        // payment failed, and e is another event's.
        assert_eq!(seats_taken(&read, "CheckoutFixture", &payments, "yoga"), 2);
        assert_eq!(seats_left(&read, "CheckoutFixture", &payments, "yoga"), Some(4));
        assert_eq!(seats_left(&read, "CheckoutFixture", &payments, "other"), Some(5), "the archived registration on `other` frees its seat");
    }

    #[test]
    fn seats_left_never_goes_below_zero_and_is_none_without_an_event_or_capacity() {
        let payments = crate::commerce_ir::fixture_payments();
        let oversold = read_with(1, &[("a", "yoga", "succeeded"), ("b", "yoga", "succeeded")]);
        assert_eq!(seats_left(&oversold, "CheckoutFixture", &payments, "yoga"), Some(0));
        assert_eq!(seats_left(&oversold, "CheckoutFixture", &payments, "nowhere"), None);
        let no_capacity = json!({"instances": {"CheckoutFixture::Event#yoga": {"name": {"value": "Yoga"}}}});
        assert_eq!(seats_left(&no_capacity, "CheckoutFixture", &payments, "yoga"), None);
    }

    // The site's own JavaScript tests of this rule (its seat-count spec) use the
    // fixtures below; the same cases run here so the two counts cannot drift.
    const HOLDING: [&str; 4] = ["pending", "succeeded", "refunding", "disputed"];
    const FREEING: [&str; 3] = ["failed", "refunded", "charged_back"];

    fn set_registration_status(read: &mut Value, reference: &str, status: &str) {
        read["instances"][format!("CheckoutFixture::Registration#{reference}")]["status"] = json!(status);
    }

    /// The fixture's payments binding with the production table: the fixture lifecycle has only
    /// pending, succeeded and failed, so refunding and disputed need the table set here.
    fn four_state_payments() -> crate::commerce_ir::PaymentsProvider {
        let mut payments = crate::commerce_ir::fixture_payments();
        payments.holds_seat = HOLDING.iter().map(|s| s.to_string()).collect();
        payments
    }

    #[test]
    fn the_seat_holding_table_comes_from_the_fixture_ir_mark() {
        assert_eq!(crate::commerce_ir::fixture_payments().holds_seat, vec!["pending", "succeeded"]);
    }

    #[test]
    fn every_holding_status_holds_one_seat_and_every_freeing_status_holds_none() {
        let payments = four_state_payments();
        for status in HOLDING {
            let read = read_with(10, &[("r", "yoga", status)]);
            assert_eq!(seats_taken(&read, "CheckoutFixture", &payments, "yoga"), 1, "{status} should hold a seat");
        }
        for status in FREEING {
            let read = read_with(10, &[("r", "yoga", status)]);
            assert_eq!(seats_taken(&read, "CheckoutFixture", &payments, "yoga"), 0, "{status} should free the seat");
        }
    }

    #[test]
    fn a_reference_reads_as_a_plain_id_or_a_wrapped_value_and_counts_per_event() {
        let payments = crate::commerce_ir::fixture_payments();
        let mut read = read_with(
            10,
            &[("a", "yoga", "succeeded"), ("b", "yoga", "pending"), ("c", "other", "pending"), ("d", "yoga", "failed")],
        );
        read["instances"]["CheckoutFixture::Registration#b"]["event_slug"] = json!({"value": "yoga"});
        assert_eq!(seats_taken(&read, "CheckoutFixture", &payments, "yoga"), 2);
        assert_eq!(seats_taken(&read, "CheckoutFixture", &payments, "other"), 1);
        read["instances"]["CheckoutFixture::Registration#a"]["event_slug"] = json!("");
        assert_eq!(seats_taken(&read, "CheckoutFixture", &payments, "yoga"), 1, "an empty event id is no reference");
    }

    #[test]
    fn a_payment_with_no_registration_is_ignored_and_a_missing_or_empty_read_counts_nothing() {
        let payments = crate::commerce_ir::fixture_payments();
        let mut read = read_with(5, &[]);
        read["instances"]["CheckoutFixture::Registration#lonely"] = json!({"event_slug": "yoga"});
        read["instances"]["Payments::Payment#orphan"] = json!({"status": "succeeded"});
        assert_eq!(seats_taken(&read, "CheckoutFixture", &payments, "yoga"), 0);
        for empty in [json!({}), json!({"instances": {}}), Value::Null] {
            assert_eq!(seats_taken(&empty, "CheckoutFixture", &payments, "yoga"), 0);
            assert!(seat_counts(&empty, "CheckoutFixture", &payments).is_empty());
        }
    }

    #[test]
    fn an_archived_registration_frees_its_seat_whichever_holding_status_its_payment_has() {
        let payments = crate::commerce_ir::fixture_payments();
        for status in HOLDING {
            let mut read = read_with(10, &[("r", "yoga", status)]);
            set_registration_status(&mut read, "r", "archived");
            assert_eq!(seats_taken(&read, "CheckoutFixture", &payments, "yoga"), 0, "archived + {status} should not hold a seat");
        }
    }

    #[test]
    fn archiving_one_of_several_guests_frees_exactly_one_seat() {
        let payments = crate::commerce_ir::fixture_payments();
        let mut read = read_with(10, &[("a", "yoga", "succeeded"), ("b", "yoga", "succeeded"), ("c", "yoga", "pending")]);
        set_registration_status(&mut read, "a", "active");
        set_registration_status(&mut read, "b", "archived");
        set_registration_status(&mut read, "c", "active");
        assert_eq!(seats_taken(&read, "CheckoutFixture", &payments, "yoga"), 2);
    }

    #[test]
    fn seat_figures_carry_capacity_taken_and_left_and_null_without_a_capacity() {
        let payments = crate::commerce_ir::fixture_payments();
        let read = read_with(3, &[("a", "yoga", "succeeded"), ("b", "yoga", "pending"), ("c", "yoga", "succeeded"), ("d", "yoga", "succeeded")]);
        assert_eq!(one_seat_figures(&read, "CheckoutFixture", &payments, "yoga"), Some(json!({"slug": "yoga", "capacity": 3, "seats_taken": 4, "seats_left": 0})));
        assert_eq!(one_seat_figures(&read, "CheckoutFixture", &payments, "nowhere"), None);
        assert_eq!(
            all_seat_figures(&read, "CheckoutFixture", &payments),
            json!({"events": {
                "yoga": {"capacity": 3, "seats_taken": 4, "seats_left": 0},
                "other": {"capacity": 5, "seats_taken": 0, "seats_left": 5},
            }})
        );
        let no_capacity = json!({"instances": {"CheckoutFixture::Event#yoga": {"name": {"value": "Yoga"}}}});
        assert_eq!(
            one_seat_figures(&no_capacity, "CheckoutFixture", &payments, "yoga"),
            Some(json!({"slug": "yoga", "capacity": null, "seats_taken": 0, "seats_left": null}))
        );
    }

    #[test]
    fn the_seat_figures_agree_with_seats_left_for_every_event() {
        let payments = crate::commerce_ir::fixture_payments();
        let mut read = read_with(6, &[("a", "yoga", "succeeded"), ("b", "yoga", "refunding"), ("c", "other", "pending"), ("d", "yoga", "failed")]);
        set_registration_status(&mut read, "b", "archived");
        let all = all_seat_figures(&read, "CheckoutFixture", &payments);
        for slug in ["yoga", "other"] {
            assert_eq!(all["events"][slug]["seats_left"].as_i64(), seats_left(&read, "CheckoutFixture", &payments, slug), "{slug}");
            assert_eq!(all["events"][slug]["seats_taken"].as_u64(), Some(seats_taken(&read, "CheckoutFixture", &payments, slug) as u64), "{slug}");
        }
    }

    #[test]
    fn only_a_single_segment_slug_between_events_and_seats_names_an_event() {
        assert_eq!(seats_path_slug("/events/yoga/seats"), Some("yoga"));
        for path in ["/events/seats", "/events//seats", "/events/a/b/seats", "/events/yoga", "/events/yoga/seats/x", "/registrations/x/seats"] {
            assert_eq!(seats_path_slug(path), None, "{path}");
        }
    }

    #[tokio::test]
    async fn the_seat_routes_answer_from_a_real_read_and_404_an_unknown_event() {
        let client = scratch_db("hecks_host_web_test_seat_routes").await;
        provision_lineage(&*client.lock().await, "CheckoutFixture", 1, &["Event", "Registration", "Payment"]).await;
        let config = checkout_config(1);
        let wasm_path = checkout_wasm_path();
        schedule_event(&client, &wasm_path, &config, "yoga", 4200).await;
        let ir = crate::commerce_ir::fixture_ir();
        let get = |path: &'static str| {
            let (client, wasm_path, config, ir) = (&client, &wasm_path, &config, &ir);
            async move {
                let response = payments_routes(Some(ir), "GET", path, "", "", client, wasm_path, config, &lambda_client::NeverInvoker).await.expect("a seats path");
                (response["statusCode"].as_u64().unwrap(), serde_json::from_str::<Value>(response["body"].as_str().unwrap()).unwrap())
            }
        };
        assert_eq!(get("/events/yoga/seats").await, (200, json!({"slug": "yoga", "capacity": 20, "seats_taken": 0, "seats_left": 20})));
        assert_eq!(get("/events/seats").await, (200, json!({"events": {"yoga": {"capacity": 20, "seats_taken": 0, "seats_left": 20}}})));
        assert_eq!(get("/events/nowhere/seats").await, (404, json!({"error": "no such event"})));
    }

    #[test]
    fn checkout_is_enabled_only_for_the_exactly_configured_domain() {
        assert!(checkout_enabled(Some("CheckoutFixture"), "CheckoutFixture"));
        assert!(!checkout_enabled(None, "CheckoutFixture"));
        assert!(!checkout_enabled(Some(""), "CheckoutFixture"));
        assert!(!checkout_enabled(Some("Banking"), "CheckoutFixture"));
    }

    #[test]
    fn attendee_from_strips_only_routing_metadata_not_attendee_fields() {
        let body = json!({
            "event_slug": "yoga-aug",
            "return_to": "/yoga-aug",
            "first_name": "Ada",
            "last_name": "Lovelace",
            "email": "ada@example.com",
            "phone": "555-0100",
            "previous_sessions": false,
            "first_time": true,
            "how_heard": "a friend",
            "aim": "flexibility",
        });

        let attendee = attendee_from(&body);

        assert_eq!(attendee.get("event_slug"), None, "routing metadata must not leak into Attendee");
        assert_eq!(attendee.get("return_to"), None, "routing metadata must not leak into Attendee");
        assert_eq!(attendee["first_name"], "Ada");
        assert_eq!(attendee["last_name"], "Lovelace");
        assert_eq!(attendee["email"], "ada@example.com");
        assert_eq!(attendee["phone"], "555-0100");
        assert_eq!(attendee["previous_sessions"], false);
        assert_eq!(attendee["first_time"], true);
        assert_eq!(attendee["how_heard"], "a friend");
        assert_eq!(attendee["aim"], "flexibility");
    }

    #[test]
    fn attendee_from_forwards_the_old_flat_shape_unchanged_for_backward_compatibility() {
        // Must round-trip byte-for-byte — this exact shape is what
        // CheckoutFixture's tests, and any simple-Attendee domain, send.
        let body = json!({"event_slug": "happy-event", "name": "Ada Lovelace", "email": "ada@example.com"});
        assert_eq!(attendee_from(&body), json!({"name": "Ada Lovelace", "email": "ada@example.com"}));
    }

    #[test]
    fn display_name_from_prefers_a_flat_name_field_when_present() {
        let body = json!({"name": "Ada Lovelace", "first_name": "should be ignored", "last_name": "should be ignored"});
        assert_eq!(display_name_from(&body), Some("Ada Lovelace".to_string()));
    }

    #[test]
    fn display_name_from_composes_first_and_last_name_when_no_flat_name_exists() {
        let body = json!({"first_name": "Ada", "last_name": "Lovelace"});
        assert_eq!(display_name_from(&body), Some("Ada Lovelace".to_string()));
    }

    #[test]
    fn display_name_from_is_none_when_neither_shape_is_present() {
        assert_eq!(display_name_from(&json!({"email": "ada@example.com"})), None);
        assert_eq!(display_name_from(&json!({"first_name": "Ada"})), None, "last_name alone is missing");
        assert_eq!(display_name_from(&json!({"last_name": "Lovelace"})), None, "first_name alone is missing");
    }

    #[tokio::test]
    async fn registrations_route_refuses_a_body_missing_any_required_field() {
        let client = scratch_db("hecks_host_web_test_registrations_missing_fields").await;
        provision_lineage(&*client.lock().await, "CheckoutFixture", 1, &["Event", "Registration", "Payment"]).await;

        let response = registrations_route(r#"{"event_slug":"yoga-aug"}"#, &payments::test_platform(), &client, &checkout_wasm_path(), &checkout_config(1), &lambda_client::NeverInvoker, &crate::commerce_ir::fixture_payments()).await;
        assert_eq!(response["statusCode"], 400);
        assert!(response["body"].as_str().unwrap().contains("missing name"));
    }

    // A caller submits `first_name`/`last_name` against CheckoutFixture's
    // `name`-only Attendee — proves display_name_from composes a real Client
    // name and attendee_from forwards fields verbatim, without a second fixture.
    #[tokio::test]
    async fn registrations_route_forwards_a_new_shaped_attendee_verbatim_even_against_an_old_shaped_fixture() {
        let client = scratch_db("hecks_host_web_test_registrations_new_shape").await;
        provision_lineage(&*client.lock().await, "CheckoutFixture", 1, &["Event", "Registration", "Payment"]).await;
        let config = checkout_config(1);
        let wasm_path = checkout_wasm_path();

        schedule_event(&client, &wasm_path, &config, "happy-event", 4200).await;

        let body = json!({
            "event_slug": "happy-event",
            "first_name": "Ada",
            "last_name": "Lovelace",
            "email": "ada@example.com",
        })
        .to_string();
        let response = registrations_route(&body, &payments::test_platform(), &client, &wasm_path, &config, &lambda_client::NeverInvoker, &crate::commerce_ir::fixture_payments()).await;

        // Registration.Request refuses (no first_name/last_name in this
        // Attendee) but only after Payment.Initiate already ran, proving
        // display_name_from composed a real name Payment accepted.
        assert_eq!(response["statusCode"], 422, "{response:?}");
        assert!(
            response["body"].as_str().unwrap().contains("name"),
            "should surface CheckoutFixture's own real Attendee refusal, not a generic error: {response:?}"
        );

        let read = dispatch::read(&client, &wasm_path).await.unwrap();
        let instances = read["instances"].as_object().unwrap();
        assert!(
            instances.keys().any(|k| k.starts_with("Payments::Payment#")),
            "Payment.Initiate should have committed for real using the composed display name: {instances:?}"
        );
        assert!(
            instances.keys().all(|k| !k.starts_with("CheckoutFixture::Registration#")),
            "Registration.Request must never have committed: {instances:?}"
        );
    }

    // A domain whose IR declares no payments capability serves none of the
    // checkout, registration-payment or webhook routes; the positive control
    // (the fixture's own IR) shows the same call is answered when it does.
    #[tokio::test]
    async fn payments_routes_serve_nothing_without_a_payments_capability() {
        let client = scratch_db("hecks_host_web_test_payments_gate").await;
        let wasm_path = checkout_wasm_path();
        let config = checkout_config(1);
        let no_payments = json!({"name": "Studio"});

        for (method, path) in [
            ("POST", "/registrations"),
            ("GET", "/registrations/REG-1"),
            ("POST", "/registrations/REG-1/complete"),
            ("POST", "/webhooks/stripe"),
            ("POST", "/events"),
            ("GET", "/events/seats"),
            ("GET", "/events/yoga/seats"),
        ] {
            for ir in [Some(&no_payments), None] {
                let response = payments_routes(ir, method, path, "not json", "", &client, &wasm_path, &config, &lambda_client::NeverInvoker).await;
                assert!(response.is_none(), "{method} {path} answered although the IR declares no payments: {response:?}");
            }
        }

        let fixture_ir = crate::commerce_ir::fixture_ir();
        let response = payments_routes(Some(&fixture_ir), "POST", "/registrations", "not json", "", &client, &wasm_path, &config, &lambda_client::NeverInvoker).await;
        assert_eq!(response.expect("the fixture IR declares payments, so the route answers")["statusCode"], 400);
    }

    #[tokio::test]
    async fn registrations_route_refuses_invalid_json_outright() {
        let client = scratch_db("hecks_host_web_test_registrations_bad_json").await;
        provision_lineage(&*client.lock().await, "CheckoutFixture", 1, &["Event", "Registration", "Payment"]).await;

        let response = registrations_route("not json", &payments::test_platform(), &client, &checkout_wasm_path(), &checkout_config(1), &lambda_client::NeverInvoker, &crate::commerce_ir::fixture_payments()).await;
        assert_eq!(response["statusCode"], 400);
    }

    #[tokio::test]
    async fn events_route_refuses_invalid_json_outright() {
        let client = scratch_db("hecks_host_web_test_events_bad_json").await;
        provision_lineage(&*client.lock().await, "CheckoutFixture", 1, &["Event", "Registration", "Payment"]).await;

        let response = events_route("not json", &client, &checkout_wasm_path(), &checkout_config(1), &lambda_client::NeverInvoker).await;
        assert_eq!(response["statusCode"], 400);
    }

    #[tokio::test]
    async fn events_route_refuses_a_body_missing_any_required_field() {
        let client = scratch_db("hecks_host_web_test_events_missing_fields").await;
        provision_lineage(&*client.lock().await, "CheckoutFixture", 1, &["Event", "Registration", "Payment"]).await;

        let response = events_route(r#"{"slug":"new-event"}"#, &client, &checkout_wasm_path(), &checkout_config(1), &lambda_client::NeverInvoker).await;
        assert_eq!(response["statusCode"], 400);
        assert!(response["body"].as_str().unwrap().contains("missing name"));
    }

    #[tokio::test]
    async fn events_route_schedules_a_new_event_and_returns_201() {
        let client = scratch_db("hecks_host_web_test_events_new").await;
        provision_lineage(&*client.lock().await, "CheckoutFixture", 1, &["Event", "Registration", "Payment"]).await;
        let config = checkout_config(1);
        let wasm_path = checkout_wasm_path();

        let body = json!({"slug": "mock-payments-event", "name": "Mock Payments Event", "price_cents": 4200, "capacity": 20}).to_string();
        let response = events_route(&body, &client, &wasm_path, &config, &lambda_client::NeverInvoker).await;
        assert_eq!(response["statusCode"], 201, "{response:?}");
        let response_body: Value = serde_json::from_str(response["body"].as_str().unwrap()).unwrap();
        assert_eq!(response_body["slug"]["value"], "mock-payments-event");
        assert_eq!(response_body["name"]["value"], "Mock Payments Event");
        assert_eq!(response_body["price"]["cents"], 4200);
        assert_eq!(response_body["capacity"]["value"], 20);
        assert_eq!(response_body["status"], "open");

        let read = dispatch::read(&client, &wasm_path).await.unwrap();
        let instances = read["instances"].as_object().unwrap();
        assert!(
            instances.keys().any(|k| k == "CheckoutFixture::Event#mock-payments-event"),
            "Event.Schedule should have committed for real: {instances:?}"
        );
    }

    // A repeat call for the same slug is a 200 no-op returning the existing
    // event's state, never a second Event.Schedule dispatch.
    #[tokio::test]
    async fn events_route_is_idempotent_on_a_repeat_slug() {
        let client = scratch_db("hecks_host_web_test_events_idempotent").await;
        provision_lineage(&*client.lock().await, "CheckoutFixture", 1, &["Event", "Registration", "Payment"]).await;
        let config = checkout_config(1);
        let wasm_path = checkout_wasm_path();

        let body = json!({"slug": "repeat-event", "name": "Repeat Event", "price_cents": 1000, "capacity": 5}).to_string();
        let first = events_route(&body, &client, &wasm_path, &config, &lambda_client::NeverInvoker).await;
        assert_eq!(first["statusCode"], 201, "{first:?}");

        // A second call with different name/price/capacity still returns the
        // original event's state, 200 not 201 — idempotency keys only on slug.
        let second_body = json!({"slug": "repeat-event", "name": "Different Name", "price_cents": 9999, "capacity": 1}).to_string();
        let second = events_route(&second_body, &client, &wasm_path, &config, &lambda_client::NeverInvoker).await;
        assert_eq!(second["statusCode"], 200, "{second:?}");
        let second_body: Value = serde_json::from_str(second["body"].as_str().unwrap()).unwrap();
        assert_eq!(second_body["name"]["value"], "Repeat Event", "must return the ORIGINAL event, not re-schedule with the new fields");
        assert_eq!(second_body["price"]["cents"], 1000);

        let read = dispatch::read(&client, &wasm_path).await.unwrap();
        let instances = read["instances"].as_object().unwrap();
        assert_eq!(
            instances.keys().filter(|k| k.starts_with("CheckoutFixture::Event#repeat-event")).count(),
            1,
            "exactly one Event, never a second dispatch: {instances:?}"
        );
    }

    #[tokio::test]
    async fn registrations_route_404s_an_unknown_event_slug() {
        let client = scratch_db("hecks_host_web_test_registrations_no_event").await;
        provision_lineage(&*client.lock().await, "CheckoutFixture", 1, &["Event", "Registration", "Payment"]).await;

        let body = json!({"event_slug": "nope", "name": "Ada", "email": "ada@example.com"}).to_string();
        let response = registrations_route(&body, &payments::test_platform(), &client, &checkout_wasm_path(), &checkout_config(1), &lambda_client::NeverInvoker, &crate::commerce_ir::fixture_payments()).await;
        assert_eq!(response["statusCode"], 404);
    }

    #[tokio::test]
    async fn registrations_route_refuses_a_closed_event() {
        let client = scratch_db("hecks_host_web_test_registrations_closed_event").await;
        provision_lineage(&*client.lock().await, "CheckoutFixture", 1, &["Event", "Registration", "Payment"]).await;
        let config = checkout_config(1);
        let wasm_path = checkout_wasm_path();

        schedule_event(&client, &wasm_path, &config, "closed-event", 4200).await;
        let close = dispatch::handle(&client, &wasm_path, "CheckoutFixture::Event.Close", json!({"id": "closed-event"}), None, &config, &lambda_client::NeverInvoker)
            .await
            .unwrap();
        assert!(close.accepted, "closing the fixture event should succeed: {:?}", close.result);

        let body = json!({"event_slug": "closed-event", "name": "Ada", "email": "ada@example.com"}).to_string();
        let response = registrations_route(&body, &payments::test_platform(), &client, &wasm_path, &config, &lambda_client::NeverInvoker, &crate::commerce_ir::fixture_payments()).await;
        assert_eq!(response["statusCode"], 422);
        assert!(response["body"].as_str().unwrap().contains("closed"));
    }

    #[tokio::test]
    async fn registrations_route_propagates_a_real_domain_refusal_from_payment_initiate() {
        // A zero-price event: PositiveMoney's invariant refuses
        // Payment.Initiate before Registration.Request is ever reached,
        // proving the refusal is the real domain rule.
        let client = scratch_db("hecks_host_web_test_registrations_zero_price").await;
        provision_lineage(&*client.lock().await, "CheckoutFixture", 1, &["Event", "Registration", "Payment"]).await;
        let config = checkout_config(1);
        let wasm_path = checkout_wasm_path();

        schedule_event(&client, &wasm_path, &config, "free-event", 0).await;

        let body = json!({"event_slug": "free-event", "name": "Ada", "email": "ada@example.com"}).to_string();
        let response = registrations_route(&body, &payments::test_platform(), &client, &wasm_path, &config, &lambda_client::NeverInvoker, &crate::commerce_ir::fixture_payments()).await;
        assert_eq!(response["statusCode"], 422);
        assert!(
            response["body"].as_str().unwrap().contains("positive"),
            "should surface PositiveMoney's own invariant text: {response:?}"
        );

        // And neither the payment nor the registration was persisted —
        // Registration.Request must never have been dispatched at all.
        let read = dispatch::read(&client, &wasm_path).await.unwrap();
        let instances = read["instances"].as_object().unwrap();
        assert!(instances.keys().all(|k| !k.starts_with("CheckoutFixture::Registration#") && !k.starts_with("Payments::Payment#")));
    }

    #[tokio::test]
    async fn registrations_route_runs_the_whole_dispatch_chain_and_returns_a_real_mock_checkout_url() {
        let client = scratch_db("hecks_host_web_test_registrations_happy_path").await;
        provision_lineage(&*client.lock().await, "CheckoutFixture", 1, &["Event", "Registration", "Payment"]).await;
        let config = checkout_config(1);
        let wasm_path = checkout_wasm_path();

        schedule_event(&client, &wasm_path, &config, "happy-event", 4200).await;

        // No connection: checkout is genuinely on the mock walkthrough, not
        // a misconfiguration — the whole chain runs and returns a real
        // checkout URL, never a 500.
        let body = json!({"event_slug": "happy-event", "name": "Ada Lovelace", "email": "ada@example.com"}).to_string();
        let response = registrations_route(&body, &payments::test_platform(), &client, &wasm_path, &config, &lambda_client::NeverInvoker, &crate::commerce_ir::fixture_payments()).await;
        assert_eq!(response["statusCode"], 200, "{response:?}");
        let body: Value = serde_json::from_str(response["body"].as_str().unwrap()).unwrap();
        let reference = body["registration_id"].as_str().unwrap().to_string();
        // LocalCheckout's shape: /pay/<reference>.html, with success_url and
        // cancel_url as encoded query params pointing at
        // registration-confirmed.html; no return_to sent, so it falls back to "/".
        assert_eq!(
            body["checkout_url"],
            format!(
                "http://localhost:4321/pay/{reference}.html?success_url=http%3A%2F%2Flocalhost%3A4321%2Fregistration-confirmed.html%3Fregistration_id%3D{reference}%26outcome%3Dsucceeded%26return_to%3D%252F&cancel_url=http%3A%2F%2Flocalhost%3A4321%2Fregistration-confirmed.html%3Fregistration_id%3D{reference}%26outcome%3Dcancelled%26return_to%3D%252F"
            )
        );

        let read = dispatch::read(&client, &wasm_path).await.unwrap();
        let instances = read["instances"].as_object().unwrap();
        let registration = instances.iter().find(|(k, _)| k.starts_with("CheckoutFixture::Registration#")).map(|(_, v)| v);
        let payment = instances.iter().find(|(k, _)| k.starts_with("Payments::Payment#")).map(|(_, v)| v);
        assert!(registration.is_some(), "Registration.Request should have committed for real: {instances:?}");
        assert!(payment.is_some(), "Payment.Initiate should have committed for real: {instances:?}");

        let registration = registration.unwrap();
        let payment = payment.unwrap();
        assert_eq!(registration["event_slug"], "happy-event");
        assert_eq!(registration["attendee"]["name"], "Ada Lovelace");
        // The Registration's id equals the Payment's reference, minted once
        // here, never independently.
        assert_eq!(registration["registration_id"]["value"], reference);
        assert_eq!(payment["reference"]["value"], reference);
        assert_eq!(payment["amount"]["cents"], 4200);
        // Mock, not "stripe": the processor checkout_plan picks with no
        // connection, which the webhook reads back off the Payment itself
        // for Payment::Succeed's "processor matches" given.
        assert_eq!(payment["processor"]["value"], "mock_stripe");
    }

    // Pins a real bug: a guest was redirected to the Event's internal slug
    // page (never a real route) instead of back to their own `return_to`,
    // 404ing every guest right after a successful, already-charged registration.
    #[tokio::test]
    async fn registrations_route_redirects_to_the_caller_s_own_return_to_not_the_event_slug() {
        let client = scratch_db("hecks_host_web_test_registrations_return_to").await;
        provision_lineage(&*client.lock().await, "CheckoutFixture", 1, &["Event", "Registration", "Payment"]).await;
        let config = checkout_config(1);
        let wasm_path = checkout_wasm_path();

        schedule_event(&client, &wasm_path, &config, "happy-event", 4200).await;

        let body = json!({
            "event_slug": "happy-event",
            "name": "Ada Lovelace",
            "email": "ada@example.com",
            "return_to": "/sample-studio.html",
        })
        .to_string();
        let response = registrations_route(&body, &payments::test_platform(), &client, &wasm_path, &config, &lambda_client::NeverInvoker, &crate::commerce_ir::fixture_payments()).await;
        assert_eq!(response["statusCode"], 200, "{response:?}");
        let body: Value = serde_json::from_str(response["body"].as_str().unwrap()).unwrap();
        let reference = body["registration_id"].as_str().unwrap().to_string();
        assert_eq!(
            body["checkout_url"],
            format!(
                "http://localhost:4321/pay/{reference}.html?success_url=http%3A%2F%2Flocalhost%3A4321%2Fregistration-confirmed.html%3Fregistration_id%3D{reference}%26outcome%3Dsucceeded%26return_to%3D%252Fsample-studio.html&cancel_url=http%3A%2F%2Flocalhost%3A4321%2Fregistration-confirmed.html%3Fregistration_id%3D{reference}%26outcome%3Dcancelled%26return_to%3D%252Fsample-studio.html"
            )
        );
    }

    // An absolute or protocol-relative return_to must never become an open
    // redirect; falls back to "/" exactly as if none had been sent.
    #[tokio::test]
    async fn registrations_route_refuses_an_absolute_or_protocol_relative_return_to() {
        let client = scratch_db("hecks_host_web_test_registrations_return_to_unsafe").await;
        provision_lineage(&*client.lock().await, "CheckoutFixture", 1, &["Event", "Registration", "Payment"]).await;
        let config = checkout_config(1);
        let wasm_path = checkout_wasm_path();

        schedule_event(&client, &wasm_path, &config, "happy-event", 4200).await;

        for unsafe_return_to in ["https://evil.example", "//evil.example"] {
            let body = json!({
                "event_slug": "happy-event",
                "name": "Ada Lovelace",
                "email": "ada@example.com",
                "return_to": unsafe_return_to,
            })
            .to_string();
            let response = registrations_route(&body, &payments::test_platform(), &client, &wasm_path, &config, &lambda_client::NeverInvoker, &crate::commerce_ir::fixture_payments()).await;
            assert_eq!(response["statusCode"], 200, "{response:?}");
            let body: Value = serde_json::from_str(response["body"].as_str().unwrap()).unwrap();
            // checkout_url is the /pay/<id>.html walkthrough page; return_to
            // is double-encoded (once for /pay's success_url, once more inside
            // it) so it shows up as "%252F".
            let checkout_url = body["checkout_url"].as_str().unwrap();
            let parsed = reqwest::Url::parse(checkout_url).unwrap();
            let success_url = parsed.query_pairs().find(|(k, _)| k == "success_url").map(|(_, v)| v.into_owned()).unwrap_or_default();
            assert!(
                success_url.ends_with("return_to=%2F"),
                "an unsafe return_to ({unsafe_return_to:?}) must fall back to \"/\": {body:?}"
            );
        }
    }

    #[tokio::test]
    async fn a_mock_registration_confirms_end_to_end_through_a_synthetic_signed_webhook() {
        // The full loop, mock both ends: registrations_route's own
        // checkout_url, then a webhook signed against the same mock secret
        // webhook_route falls back to while STRIPE_WEBHOOK_SECRET is unset.
        let client = scratch_db("hecks_host_web_test_mock_full_loop").await;
        provision_lineage(&*client.lock().await, "CheckoutFixture", 1, &["Event", "Registration", "Payment"]).await;
        let config = checkout_config(1);
        let wasm_path = checkout_wasm_path();

        schedule_event(&client, &wasm_path, &config, "mock-loop-event", 4200).await;

        let body = json!({"event_slug": "mock-loop-event", "name": "Ada Lovelace", "email": "ada@example.com"}).to_string();
        let response = registrations_route(&body, &payments::test_platform(), &client, &wasm_path, &config, &lambda_client::NeverInvoker, &crate::commerce_ir::fixture_payments()).await;
        assert_eq!(response["statusCode"], 200, "{response:?}");
        let response_body: Value = serde_json::from_str(response["body"].as_str().unwrap()).unwrap();
        let reference = response_body["registration_id"].as_str().unwrap().to_string();

        let secret = MOCK_STRIPE_WEBHOOK_SECRET;
        let payload = json!({
            "type": "checkout.session.completed",
            "data": {"object": {"id": format!("cs_manual_{reference}"), "metadata": {"registration_id": reference}}},
        }).to_string();
        let now = now_secs();
        let header = sign_stripe_header(secret, now, &payload);

        let response = webhook_route(&payload, &header, &payments::test_platform(), &client, &wasm_path, &config, &lambda_client::NeverInvoker, &crate::commerce_ir::fixture_payments()).await;
        assert_eq!(response["statusCode"], 200, "{response:?}");

        let read = dispatch::read(&client, &wasm_path).await.unwrap();
        let payment = &read["instances"][format!("Payments::Payment#{reference}")];
        assert_eq!(payment["status"], "succeeded");
        assert_eq!(payment["transaction_id"]["value"], format!("cs_manual_{reference}"));
    }

    #[tokio::test]
    async fn webhook_route_rejects_a_bad_signature_before_touching_the_domain_at_all() {
        let client = scratch_db("hecks_host_web_test_webhook_bad_sig").await;
        provision_lineage(&*client.lock().await, "CheckoutFixture", 1, &["Event", "Registration", "Payment"]).await;

        let payload = json!({"type": "checkout.session.completed", "data": {"object": {}}}).to_string();
        let bad_header = "t=1700000000,v1=deadbeef";

        let response = webhook_route(&payload, bad_header, &payments::test_platform_with_secret("whsec_test_bad_sig"), &client, &checkout_wasm_path(), &checkout_config(1), &lambda_client::NeverInvoker, &crate::commerce_ir::fixture_payments()).await;
        assert_eq!(response["statusCode"], 400);
    }

    #[tokio::test]
    async fn webhook_route_settles_a_payment_on_checkout_session_completed() {
        let client = scratch_db("hecks_host_web_test_webhook_completed").await;
        provision_lineage(&*client.lock().await, "CheckoutFixture", 1, &["Event", "Registration", "Payment"]).await;
        let config = checkout_config(1);
        let wasm_path = checkout_wasm_path();

        schedule_event(&client, &wasm_path, &config, "webhook-event", 4200).await;
        let initiate = dispatch::handle(
            &client, &wasm_path, "Payments::Payment.Initiate",
            json!({
                "reference": {"value": "REG-WEBHOOK-1"}, "processor": {"value": "stripe"},
                "payment_type": {"value": "card"}, "amount": {"cents": 4200},
                "client": {"name": "Ada Lovelace", "email": "ada@example.com"},
            }),
            None, &config, &lambda_client::NeverInvoker,
        ).await.unwrap();
        assert!(initiate.accepted, "{:?}", initiate.result);

        let secret = "whsec_test_completed";
        let payload = json!({
            "type": "checkout.session.completed",
            "data": {"object": {"metadata": {"registration_id": "REG-WEBHOOK-1"}, "payment_intent": "pi_test_abc"}},
        }).to_string();
        let now = now_secs();
        let header = sign_stripe_header(secret, now, &payload);

        let response = webhook_route(&payload, &header, &payments::test_platform_with_secret(secret), &client, &wasm_path, &config, &lambda_client::NeverInvoker, &crate::commerce_ir::fixture_payments()).await;
        assert_eq!(response["statusCode"], 200, "{response:?}");

        let read = dispatch::read(&client, &wasm_path).await.unwrap();
        let payment = &read["instances"]["Payments::Payment#REG-WEBHOOK-1"];
        assert_eq!(payment["status"], "succeeded");
        assert_eq!(payment["transaction_id"]["value"], "pi_test_abc");

        // A redelivered webhook (Stripe's delivery is at-least-once) for an
        // already-succeeded payment must still answer 200 — the refusal
        // underneath is a benign no-op, not surfaced as an error.
        let redelivered = webhook_route(&payload, &header, &payments::test_platform_with_secret(secret), &client, &wasm_path, &config, &lambda_client::NeverInvoker, &crate::commerce_ir::fixture_payments()).await;
        assert_eq!(redelivered["statusCode"], 200, "a redelivered webhook must not surface the resulting refusal as an error: {redelivered:?}");
    }

    #[tokio::test]
    async fn webhook_route_declines_a_payment_on_checkout_session_expired() {
        let client = scratch_db("hecks_host_web_test_webhook_expired").await;
        provision_lineage(&*client.lock().await, "CheckoutFixture", 1, &["Event", "Registration", "Payment"]).await;
        let config = checkout_config(1);
        let wasm_path = checkout_wasm_path();

        schedule_event(&client, &wasm_path, &config, "webhook-event-2", 4200).await;
        dispatch::handle(
            &client, &wasm_path, "Payments::Payment.Initiate",
            json!({
                "reference": {"value": "REG-WEBHOOK-2"}, "processor": {"value": "stripe"},
                "payment_type": {"value": "card"}, "amount": {"cents": 4200},
                "client": {"name": "Ada Lovelace", "email": "ada@example.com"},
            }),
            None, &config, &lambda_client::NeverInvoker,
        ).await.unwrap().accepted.then_some(()).expect("initiate should succeed");

        let secret = "whsec_test_expired";
        let payload = json!({
            "type": "checkout.session.expired",
            "data": {"object": {"metadata": {"registration_id": "REG-WEBHOOK-2"}}},
        }).to_string();
        let now = now_secs();
        let header = sign_stripe_header(secret, now, &payload);

        let response = webhook_route(&payload, &header, &payments::test_platform_with_secret(secret), &client, &wasm_path, &config, &lambda_client::NeverInvoker, &crate::commerce_ir::fixture_payments()).await;
        assert_eq!(response["statusCode"], 200, "{response:?}");

        let read = dispatch::read(&client, &wasm_path).await.unwrap();
        let payment = &read["instances"]["Payments::Payment#REG-WEBHOOK-2"];
        assert_eq!(payment["status"], "failed");
        assert_eq!(payment["failure_reason"]["value"], "checkout_expired");
    }

    #[tokio::test]
    async fn webhook_route_ignores_an_event_type_it_does_not_handle_and_still_answers_200() {
        let client = scratch_db("hecks_host_web_test_webhook_unhandled_type").await;
        provision_lineage(&*client.lock().await, "CheckoutFixture", 1, &["Event", "Registration", "Payment"]).await;

        let secret = "whsec_test_unhandled";
        let payload = json!({"type": "charge.refunded", "data": {"object": {"metadata": {"registration_id": "whatever"}}}}).to_string();
        let now = now_secs();
        let header = sign_stripe_header(secret, now, &payload);

        let response = webhook_route(&payload, &header, &payments::test_platform_with_secret(secret), &client, &checkout_wasm_path(), &checkout_config(1), &lambda_client::NeverInvoker, &crate::commerce_ir::fixture_payments()).await;
        assert_eq!(response["statusCode"], 200);
    }
}
