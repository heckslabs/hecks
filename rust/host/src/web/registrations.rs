use super::{instances_for, last_refusal, respond, with_id};
use crate::checkout;
use crate::clock::unix_now;
use crate::commerce_ir::{payments_provider, PaymentsProvider};
use crate::dispatch;
use crate::host::Host;
use crate::journal::LineageConfig;
use crate::payments;
use serde_json::{json, Value};
use std::collections::HashMap;
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
        .and_then(|(_, payment)| {
            payment
                .get("processor")
                .and_then(|p| p.get("value"))
                .and_then(|v| v.as_str())
                .map(String::from)
        })
}

// Payment statuses whose registration still holds a seat come from the
// payment lifecycle's `holds_seat` mark (`PaymentsProvider::holds_seat`). A
// registration with no Payment, or one in a state that frees its seat, holds none.
// A mock walkthrough payment still waiting to be settled holds none either: anyone may open
// one, nothing ever lapses it, and its seat is taken when it is settled instead.

/// The processor a Payment records when checkout is the mock walkthrough.
const MOCK_PROCESSOR: &str = "mock_stripe";

/// The status a Payment waits in until its processor settles it.
const PENDING: &str = "pending";

/// A Payment's `status`, when it has one.
fn payment_status(read: &Value, payments: &PaymentsProvider, reference: &str) -> Option<String> {
    instances_for(read, &payments.instance_prefix())
        .into_iter()
        .find(|(id, _)| id == reference)
        .and_then(|(_, payment)| {
            payment
                .get("status")
                .and_then(|s| s.as_str())
                .map(String::from)
        })
}

/// Whether a Payment holds its registration's seat: its status is one `holds_seat` lists, and
/// it is not a mock walkthrough payment still waiting to be settled.
fn payment_holds_seat(payment: &Value, payments: &PaymentsProvider) -> bool {
    let Some(status) = payment.get("status").and_then(|s| s.as_str()) else {
        return false;
    };
    let processor = plain_id(payment.get("processor"));
    let waiting_walkthrough = status == PENDING && processor.as_deref() == Some(MOCK_PROCESSOR);
    payments.holds_seat.iter().any(|held| held == status) && !waiting_walkthrough
}

/// Whether a registration's own lifecycle state is one the chapter declares gives its seat
/// back (`RegistrationsProvider::frees_seat`). A missing or non-text `status` is active.
fn registration_frees_seat(registration: &Value, frees_seat: &[String]) -> bool {
    let status = registration.get("status").and_then(|s| s.as_str());
    status.is_some_and(|status| frees_seat.iter().any(|freed| freed == status))
}

/// A reference to an aggregate reads back as its plain id, or wrapped as
/// `{"value": id}`; an empty id is no reference.
fn plain_id(raw: Option<&Value>) -> Option<String> {
    let raw = raw?;
    let value = raw.get("value").unwrap_or(raw);
    value.as_str().filter(|id| !id.is_empty()).map(String::from)
}

/// Seats used per event slug: Registrations not in a seat-freeing state whose Payment (same
/// reference) is in a seat-holding status.
fn seat_counts(
    read: &Value,
    domain: &str,
    payments: &PaymentsProvider,
) -> std::collections::HashMap<String, usize> {
    let binding = crate::commerce_ir::registrations_binding(domain);
    count_seats(read, &binding, payments)
}

/// The seat count of `seat_counts` against an explicit registrations binding.
fn count_seats(
    read: &Value,
    binding: &crate::commerce_ir::RegistrationsProvider,
    payments: &PaymentsProvider,
) -> std::collections::HashMap<String, usize> {
    let holding: std::collections::HashSet<String> =
        instances_for(read, &payments.instance_prefix())
            .into_iter()
            .filter(|(_, payment)| payment_holds_seat(payment, payments))
            .map(|(id, _)| id)
            .collect();
    let mut counts = std::collections::HashMap::new();
    for (id, registration) in instances_for(read, &binding.registration_prefix()) {
        let holds = holding.contains(&id);
        let freed = registration_frees_seat(&registration, &binding.frees_seat);
        if let (true, false, Some(event_slug)) =
            (holds, freed, plain_id(registration.get("event_slug")))
        {
            *counts.entry(event_slug).or_insert(0) += 1;
        }
    }
    counts
}

/// How many seats one event has used.
pub(crate) fn seats_taken(
    read: &Value,
    domain: &str,
    payments: &PaymentsProvider,
    event_slug: &str,
) -> usize {
    seat_counts(read, domain, payments)
        .get(event_slug)
        .copied()
        .unwrap_or(0)
}

/// An event's capacity, when it carries a readable one.
fn event_capacity(event: &Value) -> Option<i64> {
    event
        .get("capacity")
        .and_then(|c| c.get("value"))
        .and_then(serde_json::Value::as_i64)
}

/// A whole-number field read as a bare number or as a single-field value
/// object's `{"value": N}`; `None` for anything else, so an unreadable value
/// never blocks a registration.
fn whole_number(field: Option<&Value>) -> Option<i64> {
    let field = field?;
    field
        .as_i64()
        .or_else(|| field.get("value").and_then(serde_json::Value::as_i64))
}

/// Whether an event's registration window has shut because its start is
/// nearer than `registration_cutoff_hours` (Unix seconds, whole hours).
/// Refused only when both `starts_at` and `registration_cutoff_hours` are
/// readable and `now_secs + hours * 3600 > starts_at`; exactly at the
/// cutoff is still open. Either field absent, null or unreadable means no
/// cutoff, the stance the seat check takes.
fn registration_cutoff_passed(event: &Value, now_secs: i64) -> bool {
    let (Some(starts_at), Some(hours)) = (
        whole_number(event.get("starts_at")),
        whole_number(event.get("registration_cutoff_hours")),
    ) else {
        return false;
    };
    now_secs.saturating_add(hours.saturating_mul(3600)) > starts_at
}

/// Seats still open given `taken`, never below zero.
fn open_seats(capacity: i64, taken: usize) -> i64 {
    (capacity - taken as i64).max(0)
}

/// Seats still open on one event, never below zero; `None` when there is no
/// such event or it carries no readable capacity.
pub(crate) fn seats_left(
    read: &Value,
    domain: &str,
    payments: &PaymentsProvider,
    event_slug: &str,
) -> Option<i64> {
    let events = instances_for(
        read,
        &crate::commerce_ir::registrations_binding(domain).event_prefix(),
    );
    let (_, event) = events.iter().find(|(id, _)| id == event_slug)?;
    Some(open_seats(
        event_capacity(event)?,
        seats_taken(read, domain, payments, event_slug),
    ))
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
    let events = instances_for(
        read,
        &crate::commerce_ir::registrations_binding(domain).event_prefix(),
    );
    let figures: serde_json::Map<String, Value> = events
        .iter()
        .map(|(slug, event)| {
            (
                slug.clone(),
                seat_figures(event, counts.get(slug).copied().unwrap_or(0)),
            )
        })
        .collect();
    json!({"events": figures})
}

/// The seat figures of one event, with its `slug`; `None` when there is no such event.
fn one_seat_figures(
    read: &Value,
    domain: &str,
    payments: &PaymentsProvider,
    event_slug: &str,
) -> Option<Value> {
    let events = instances_for(
        read,
        &crate::commerce_ir::registrations_binding(domain).event_prefix(),
    );
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
async fn seats_route(
    path: &str,
    client: &Mutex<Client>,
    wasm_path: &Path,
    config: &LineageConfig,
    payments: &PaymentsProvider,
) -> Value {
    let read = match dispatch::read(client, wasm_path).await {
        Ok(r) => r,
        Err(e) => return respond(500, "text/plain", &format!("{e:#}")),
    };
    let body = match seats_path_slug(path) {
        None => all_seat_figures(&read, &config.domain, payments),
        Some(slug) => match one_seat_figures(&read, &config.domain, payments, slug) {
            Some(figures) => figures,
            None => {
                return respond(
                    404,
                    "application/json",
                    &json!({"error": "no such event"}).to_string(),
                )
            }
        },
    };
    respond(200, "application/json", &body.to_string())
}

// Serves the checkout, registration-payment and webhook routes only when the
// domain's IR declares `provides "payments"`. Takes the IR as a parameter,
// not `ir()`, so the gate can be tested against one that lacks the key.
pub(super) async fn payments_routes(
    domain_ir: Option<&Value>,
    method: &str,
    path: &str,
    raw_body: &str,
    request: &CheckoutRequest<'_>,
    host: Host<'_>,
) -> Option<Value> {
    let domain_ir = domain_ir?;
    let payments = payments_provider(domain_ir)?;
    checkout_route(method, path, raw_body, request, host, domain_ir, &payments).await
}

/// What a checkout route reads off the request besides its method, path and body.
pub(super) struct CheckoutRequest<'a> {
    /// The `Stripe-Signature` header, empty when absent.
    pub stripe_signature: &'a str,
    /// The request's cookies, which carry the account cookie POST /events checks.
    pub cookies: &'a HashMap<String, String>,
}

pub(super) async fn checkout_route(
    method: &str,
    path: &str,
    raw_body: &str,
    request: &CheckoutRequest<'_>,
    host: Host<'_>,
    domain_ir: &Value,
    payments: &PaymentsProvider,
) -> Option<Value> {
    let Host {
        client,
        wasm_path,
        config,
        ..
    } = host;
    match (method, path) {
        ("POST", "/registrations") => Some(
            registrations_route(
                raw_body,
                &payments::PlatformConfig::load().await,
                host,
                payments,
            )
            .await,
        ),
        // GET /registrations/:id: read-only, re-derives state server-side
        // for the confirmation and pay pages rather than trusting their own
        // query string.
        ("GET", path) if path.starts_with("/registrations/") && !path.ends_with("/complete") => {
            let registration_id = path.trim_start_matches("/registrations/");
            Some(
                registration_show_route(registration_id, client, wasm_path, config, payments).await,
            )
        }
        // POST /registrations/:id/complete: mock checkout's Pay/Cancel button,
        // refused unless checkout is the walkthrough and the Payment's own processor is
        // "mock_stripe". Settles
        // through the same PaymentGateway port as POST /webhooks/stripe.
        ("POST", path) if path.starts_with("/registrations/") && path.ends_with("/complete") => {
            let registration_id = path
                .trim_start_matches("/registrations/")
                .trim_end_matches("/complete")
                .trim_end_matches('/');
            Some(
                registration_complete_route(
                    registration_id,
                    raw_body,
                    &payments::PlatformConfig::load().await,
                    host,
                    payments,
                )
                .await,
            )
        }
        ("POST", "/webhooks/stripe") => Some(
            webhook_route(
                raw_body,
                request.stripe_signature,
                &payments::PlatformConfig::load().await,
                host,
                payments,
            )
            .await,
        ),
        ("GET", "/events/seats") => {
            Some(seats_route(path, client, wasm_path, config, payments).await)
        }
        ("GET", path) if seats_path_slug(path).is_some() => {
            Some(seats_route(path, client, wasm_path, config, payments).await)
        }
        // POST /events: an Admin or Owner schedules a new session by hand. The CMS schedules
        // through the internal dispatch protocol instead, so this route answers no guest.
        ("POST", "/events") => Some(
            events_route(
                raw_body,
                domain_ir,
                request.cookies,
                // Unset, it verifies no cookie, so every caller is refused.
                &crate::secrets::var("SESSION_SECRET").unwrap_or_default(),
                host,
            )
            .await,
        ),
        _ => None,
    }
}

/// The account cookie's person, when they are an active Admin or Owner; otherwise the 401 or 403
/// to answer. Read before anything else, so a refused caller learns nothing about the domain.
async fn require_admin_caller(
    domain_ir: &Value,
    cookies: &HashMap<String, String>,
    secret: &str,
    client: &Mutex<Client>,
) -> Result<String, Value> {
    let Some(caller) = cookies
        .get(&crate::auth::account_cookie_name())
        .filter(|_| !secret.is_empty())
        .and_then(|token| crate::auth::verify_account_token(secret, token))
    else {
        return Err(super::json_error(401, "not logged in"));
    };
    match crate::auth::caller_is_admin(client, domain_ir, &caller).await {
        Ok(true) => Ok(caller),
        Ok(false) => Err(super::json_error(403, "admins only")),
        Err(e) => Err(super::json_error(
            500,
            &format!("members lookup failed: {e}"),
        )),
    }
}

/// The fields POST /events schedules an event with, as `Event.Schedule` takes them.
fn schedule_args(body: &Value) -> Result<Value, Value> {
    let missing = |field: &str| {
        respond(
            400,
            "application/json",
            &json!({"error": format!("missing {field}")}).to_string(),
        )
    };
    let slug = body
        .get("slug")
        .and_then(|v| v.as_str())
        .ok_or_else(|| missing("slug"))?;
    let name = body
        .get("name")
        .and_then(|v| v.as_str())
        .ok_or_else(|| missing("name"))?;
    let price_cents = body
        .get("price_cents")
        .and_then(Value::as_i64)
        .ok_or_else(|| missing("price_cents"))?;
    let capacity = body
        .get("capacity")
        .and_then(Value::as_i64)
        .ok_or_else(|| missing("capacity"))?;
    Ok(json!({
        "slug": {"value": slug},
        "name": {"value": name},
        "price": {"cents": price_cents},
        "capacity": {"value": capacity},
    }))
}

/// Whether a scheduled event already carries the name, price and capacity of `args`. A
/// single-field value reads the same bare or wrapped as `{"value": ...}`.
fn schedules_the_same(event: &Value, args: &Value) -> bool {
    let plain = |v: &Value, field: &str| {
        v.get(field)
            .map(|value| value.get("value").unwrap_or(value).clone())
    };
    let cents = |v: &Value| v.get("price").and_then(|p| p.get("cents")).cloned();
    ["name", "capacity"]
        .iter()
        .all(|field| plain(event, field) == plain(args, field))
        && cents(event) == cents(args)
}

/// POST /events. Dispatches `<domain>::Event.Schedule` — Event is this deploy's own top-level
/// aggregate, not a vendored chapter like Payments — for an active Admin or Owner holding the
/// account cookie. The host vouches for the caller as GET /registrations does and dispatches
/// host-internally: a member's role (Admin, Owner) is not one the domain's commands declare.
/// A repeat call for a scheduled slug answers the event as it stands when every field matches,
/// and 409 when any differs, so nobody can hold a slug at a price the editor never set.
async fn events_route(
    raw_body: &str,
    domain_ir: &Value,
    cookies: &HashMap<String, String>,
    secret: &str,
    host: Host<'_>,
) -> Value {
    let Host {
        client,
        wasm_path,
        config,
        ..
    } = host;
    if let Err(response) = require_admin_caller(domain_ir, cookies, secret, client).await {
        return response;
    }
    let body: Value = match serde_json::from_str(raw_body) {
        Ok(v) => v,
        Err(e) => {
            return respond(
                400,
                "application/json",
                &json!({"error": format!("invalid JSON: {e}")}).to_string(),
            )
        }
    };
    let args = match schedule_args(&body) {
        Ok(args) => args,
        Err(response) => return response,
    };
    let slug = args["slug"]["value"]
        .as_str()
        .unwrap_or_default()
        .to_string();

    let read = match dispatch::read(client, wasm_path).await {
        Ok(r) => r,
        Err(e) => return respond(500, "text/plain", &format!("{e:#}")),
    };
    let events = instances_for(
        &read,
        &crate::commerce_ir::registrations_binding(&config.domain).event_prefix(),
    );
    if let Some((_, existing)) = events.iter().find(|(id, _)| *id == slug) {
        if !schedules_the_same(existing, &args) {
            return respond(
                409,
                "application/json",
                &json!({"error": "an event with this slug is already scheduled with other details"})
                    .to_string(),
            );
        }
        return respond(
            200,
            "application/json",
            &serde_json::to_string_pretty(&with_id(&slug, existing)).unwrap_or_default(),
        );
    }

    let verb = crate::commerce_ir::registrations_binding(&config.domain).schedule;
    let outcome = match dispatch::handle(host, &verb, args, None).await {
        Ok(o) => o,
        Err(e) => return respond(500, "text/plain", &format!("{e:#}")),
    };
    if !outcome.accepted {
        return respond(
            422,
            "application/json",
            &last_refusal(&outcome.result).to_string(),
        );
    }

    let read = match dispatch::read(client, wasm_path).await {
        Ok(r) => r,
        Err(e) => return respond(500, "text/plain", &format!("{e:#}")),
    };
    let events = instances_for(
        &read,
        &crate::commerce_ir::registrations_binding(&config.domain).event_prefix(),
    );
    let Some((_, event)) = events.iter().find(|(id, _)| *id == slug) else {
        return respond(
            500,
            "text/plain",
            "event vanished immediately after being scheduled",
        );
    };
    respond(
        201,
        "application/json",
        &serde_json::to_string_pretty(&with_id(&slug, event)).unwrap_or_default(),
    )
}

/// GET /registrations/:id: the event, the attendee's name, and amount_cents and payment_status
/// from the same-reference Payment. Anyone holding the id may ask (it rides in the pay and
/// confirmation URLs), so the answer carries no contact detail: no email, no phone.
async fn registration_show_route(
    registration_id: &str,
    client: &Mutex<Client>,
    wasm_path: &Path,
    config: &LineageConfig,
    payments: &PaymentsProvider,
) -> Value {
    let read = match dispatch::read(client, wasm_path).await {
        Ok(r) => r,
        Err(e) => return respond(500, "text/plain", &format!("{e:#}")),
    };
    let registrations = instances_for(
        &read,
        &crate::commerce_ir::registrations_binding(&config.domain).registration_prefix(),
    );
    let Some((_, registration)) = registrations.iter().find(|(id, _)| id == registration_id) else {
        return respond(
            404,
            "application/json",
            &json!({"error": "no such registration"}).to_string(),
        );
    };
    let event_slug = registration.get("event_slug").and_then(|v| v.as_str());
    let events = instances_for(
        &read,
        &crate::commerce_ir::registrations_binding(&config.domain).event_prefix(),
    );
    let event = event_slug
        .and_then(|slug| events.iter().find(|(id, _)| id == slug))
        .map(|(_, e)| e);

    let payment_instances = instances_for(&read, &payments.instance_prefix());
    let payment = payment_instances
        .iter()
        .find(|(id, _)| id == registration_id)
        .map(|(_, p)| p);

    let attendee = registration
        .get("attendee")
        .cloned()
        .unwrap_or_else(|| json!({}));
    respond(200, "application/json", &json!({
        "registration_id": registration_id,
        "event": {
            "slug": event_slug,
            "name": event.and_then(|e| e.get("name")).and_then(|n| n.get("value")).and_then(|v| v.as_str()),
        },
        "attendee": {
            "first_name": attendee.get("first_name"),
            "last_name": attendee.get("last_name"),
        },
        "amount_cents": payment.and_then(|p| p.get("amount")).and_then(|a| a.get("cents")),
        "payment_status": payment.and_then(|p| p.get("status")),
    }).to_string())
}

/// POST /registrations/:id/complete. Refused unless checkout is the mock walkthrough right now
/// and the Payment itself was initiated on "mock_stripe", so a walkthrough payment left over from
/// before real payments were switched on can never be settled for free; settles through the same
/// PaymentGateway port webhook_route uses. A walkthrough payment holds no seat while it waits, so
/// a success takes the seat here and is refused when the event has none left.
pub(crate) async fn registration_complete_route(
    registration_id: &str,
    raw_body: &str,
    platform: &payments::PlatformConfig,
    host: Host<'_>,
    payments: &PaymentsProvider,
) -> Value {
    let Host {
        client,
        wasm_path,
        config,
        ..
    } = host;
    let body: Value = match serde_json::from_str(raw_body) {
        Ok(v) => v,
        Err(e) => {
            return respond(
                400,
                "application/json",
                &json!({"error": format!("invalid JSON: {e}")}).to_string(),
            )
        }
    };
    let Some(outcome) = body.get("outcome").and_then(|v| v.as_str()) else {
        return respond(
            400,
            "application/json",
            &json!({"error": "missing outcome"}).to_string(),
        );
    };
    if outcome != "succeeded" && outcome != "failed" {
        return respond(
            400,
            "application/json",
            &json!({"error": "outcome must be \"succeeded\" or \"failed\""}).to_string(),
        );
    }

    let read = match dispatch::read(client, wasm_path).await {
        Ok(r) => r,
        Err(e) => return respond(500, "text/plain", &format!("{e:#}")),
    };
    let registrations = instances_for(
        &read,
        &crate::commerce_ir::registrations_binding(&config.domain).registration_prefix(),
    );
    let Some((_, registration)) = registrations.iter().find(|(id, _)| id == registration_id) else {
        return respond(
            404,
            "application/json",
            &json!({"error": "no such registration"}).to_string(),
        );
    };

    let walkthrough = matches!(
        payments::checkout_plan(
            payments::connection(&read, &config.domain).as_ref(),
            platform
        ),
        payments::CheckoutPlan::Mock
    );
    let processor = match payment_processor(&read, payments, registration_id) {
        Some(processor) if walkthrough && processor == MOCK_PROCESSOR => processor,
        _ => {
            return respond(
                403,
                "application/json",
                &json!({"error": "not available with a real payment processor"}).to_string(),
            )
        }
    };
    let event_slug = plain_id(registration.get("event_slug")).unwrap_or_default();
    let waiting = payment_status(&read, payments, registration_id).as_deref() == Some(PENDING);
    if outcome == "succeeded"
        && waiting
        && seats_left(&read, &config.domain, payments, &event_slug) == Some(0)
    {
        return respond(
            409,
            "application/json",
            &json!({"error": "this event is full"}).to_string(),
        );
    }
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
    let outcome_result =
        match dispatch::handle_routed(host, verb, json!(registration_id), facts, None).await {
            Ok(o) => o,
            Err(e) => return respond(500, "text/plain", &format!("{e:#}")),
        };
    // A repeat Succeeded/Failed on an already-settled Payment is a silent
    // no-op on Payment's own `given`, so it isn't surfaced as a 422 here
    // either.
    if !outcome_result.accepted {
        let refusal = last_refusal(&outcome_result.result);
        let already_settled = refusal
            .get("error")
            .and_then(|v| v.as_str())
            .is_some_and(|s| s.contains("pending"));
        if !already_settled {
            return respond(422, "application/json", &refusal.to_string());
        }
    }

    // Only a payment that settled just now earns a receipt; a repeat click was
    // refused above as already settled.
    if outcome == "succeeded" && outcome_result.accepted {
        super::registration_receipt::deliver_receipt(registration_id, host, payments).await;
    }

    let read = match dispatch::read(client, wasm_path).await {
        Ok(r) => r,
        Err(e) => return respond(500, "text/plain", &format!("{e:#}")),
    };
    let payment_instances = instances_for(&read, &payments.instance_prefix());
    let status = payment_instances
        .iter()
        .find(|(id, _)| id == registration_id)
        .and_then(|(_, p)| p.get("status"))
        .and_then(|v| v.as_str())
        .unwrap_or("");
    respond(
        200,
        "application/json",
        &json!({"registration_id": registration_id, "payment_status": status}).to_string(),
    )
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
pub(crate) async fn registrations_route(
    raw_body: &str,
    platform: &payments::PlatformConfig,
    host: Host<'_>,
    payments: &PaymentsProvider,
) -> Value {
    registrations_route_at(raw_body, platform, host, payments, unix_now()).await
}

// The route with the wall clock passed in, so a test can fix the time the
// registration cutoff is measured against.
pub(crate) async fn registrations_route_at(
    raw_body: &str,
    platform: &payments::PlatformConfig,
    host: Host<'_>,
    payments: &PaymentsProvider,
    now_secs: i64,
) -> Value {
    let Host {
        client,
        wasm_path,
        config,
        ..
    } = host;
    let body: Value = match serde_json::from_str(raw_body) {
        Ok(v) => v,
        Err(e) => {
            return respond(
                400,
                "application/json",
                &json!({"error": format!("invalid JSON: {e}")}).to_string(),
            )
        }
    };
    let Some(event_slug) = body.get("event_slug").and_then(|v| v.as_str()) else {
        return respond(
            400,
            "application/json",
            &json!({"error": "missing event_slug"}).to_string(),
        );
    };
    // Cheap early exits before dispatching Payment.Initiate — full Attendee
    // validation still happens downstream in Registration.Request's own
    // given/invariant checks.
    let Some(name) = display_name_from(&body) else {
        return respond(
            400,
            "application/json",
            &json!({"error": "missing name (or first_name and last_name)"}).to_string(),
        );
    };
    let Some(email) = body.get("email").and_then(|v| v.as_str()) else {
        return respond(
            400,
            "application/json",
            &json!({"error": "missing email"}).to_string(),
        );
    };

    let read = match dispatch::read(client, wasm_path).await {
        Ok(r) => r,
        Err(e) => return respond(500, "text/plain", &format!("{e:#}")),
    };
    let events = instances_for(
        &read,
        &crate::commerce_ir::registrations_binding(&config.domain).event_prefix(),
    );
    let Some((_, event)) = events.iter().find(|(id, _)| id == event_slug) else {
        return respond(
            404,
            "application/json",
            &json!({"error": "no such event"}).to_string(),
        );
    };
    if event.get("status").and_then(|v| v.as_str()) != Some("open") {
        return respond(
            422,
            "application/json",
            &json!({"error": "registration is closed for this event"}).to_string(),
        );
    }
    // An event that opted into a cutoff stops taking registrations that many
    // hours before it starts; a missing or unreadable field is no cutoff.
    if registration_cutoff_passed(event, now_secs) {
        return respond(
            422,
            "application/json",
            &json!({"error": "registration has closed for this event"}).to_string(),
        );
    }
    // A full event refuses before any Stripe call or write. An event whose
    // capacity cannot be read is not blocked: capacity is required when an
    // event is scheduled, so its absence means nothing to enforce.
    if seats_left(&read, &config.domain, payments, event_slug) == Some(0) {
        return respond(
            409,
            "application/json",
            &json!({"error": "this event is full"}).to_string(),
        );
    }
    let price_cents = event
        .get("price")
        .and_then(|p| p.get("cents"))
        .and_then(serde_json::Value::as_i64)
        .unwrap_or(0);
    let event_name = event
        .get("name")
        .and_then(|n| n.get("value"))
        .and_then(|v| v.as_str())
        .unwrap_or("");

    // What checkout does is decided per request from this tenant's own
    // PaymentConnection, before anything is written — a connection that is
    // not enabled must never fall back to the mock walkthrough.
    let plan = payments::checkout_plan(
        payments::connection(&read, &config.domain).as_ref(),
        platform,
    );
    let processor = match plan {
        payments::CheckoutPlan::Mock => MOCK_PROCESSOR,
        payments::CheckoutPlan::Stripe { .. } => "stripe",
        payments::CheckoutPlan::Paused => {
            return respond(
                503,
                "application/json",
                &json!({"error": "payments are temporarily unavailable"}).to_string(),
            );
        }
    };
    let site_url = platform.site_url.as_str();

    let reference = uuid::Uuid::new_v4().to_string();

    // A Stripe plan opens its embedded session before anything is written, so
    // a failure leaves no Payment or Registration behind. If a domain refusal
    // follows, the unused session simply expires.
    let embedded_checkout = if let payments::CheckoutPlan::Stripe {
        api_key,
        publishable_key,
    } = &plan
    {
        let auth = checkout::StripeAuth {
            api_key,
            base_url: &platform.api_base,
        };
        match checkout::create_checkout_session(
            &auth,
            price_cents,
            event_name,
            &reference,
            checkout::session_expires_at(
                now_secs,
                crate::commerce_ir::checkout_windows_binding().session_hold,
            ),
        )
        .await
        {
            // Stripe.js is opened with the publishable key; the answer carries
            // no `checkout_url`.
            Ok(session) => Some(json!({
                "client_secret": session.client_secret,
                "publishable_key": publishable_key,
                "session_id": session.session_id,
            })),
            Err(e) => {
                eprintln!(
                    "registrations: opening the Stripe session failed, nothing was recorded: {e:#}"
                );
                return respond(
                    502,
                    "application/json",
                    &json!({"error": "payments are temporarily unavailable"}).to_string(),
                );
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
    let outcome = match dispatch::handle(host, &payments.initiate, initiate_args, None).await {
        Ok(o) => o,
        Err(e) => return respond(500, "text/plain", &format!("{e:#}")),
    };
    if !outcome.accepted {
        return respond(
            422,
            "application/json",
            &last_refusal(&outcome.result).to_string(),
        );
    }

    let mut request_args = json!({
        "event_slug": event_slug,
        "registration_id": {"value": reference},
        "attendee": attendee_from(&body),
    });
    // A reaction reads only fields its event carries, never ones nested
    // inside `attendee`, so newsletter fields are declared flat on
    // Registration.Request; a command refuses args it doesn't declare.
    let news_signup = body
        .get("news_signup")
        .and_then(serde_json::Value::as_bool)
        .unwrap_or(false);
    let binding = crate::commerce_ir::registrations_binding(&config.domain);
    let forwards_newsletter = crate::ir::ir().is_some_and(|ir| {
        binding
            .request_target()
            .is_some_and(|(aggregate, command)| {
                crate::commerce_ir::command_declares(ir, aggregate, command, "news_signup")
            })
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
    let outcome = match dispatch::handle(host, &request_verb, request_args, None).await {
        Ok(o) => o,
        Err(e) => return respond(500, "text/plain", &format!("{e:#}")),
    };
    if !outcome.accepted {
        return respond(
            422,
            "application/json",
            &last_refusal(&outcome.result).to_string(),
        );
    }
    if let Some(full) =
        give_back_an_oversold_seat(&reference, event_slug, processor, host, payments).await
    {
        return full;
    }

    // The domain's reaction has already subscribed the address by now; a
    // registrant who ticked the box gets the same signed confirm link as the
    // footer form. Best effort: the registration stands whatever mail does.
    if forwards_newsletter && news_signup {
        super::newsletter::send_confirmation_if_pending(email, client, wasm_path).await;
    }

    if let Some(embedded) = embedded_checkout {
        return respond(
            200,
            "application/json",
            &json!({"registration_id": reference, "embedded_checkout": embedded}).to_string(),
        );
    }

    // `return_to` is guest-supplied and never trusted raw — only a same-site
    // path (one leading slash, not two) is kept, since e.g. "//evil.example"
    // would otherwise be an open redirect; anything else falls back to "/".
    let return_to = match body.get("return_to").and_then(|v| v.as_str()) {
        Some(path) if path.starts_with('/') && !path.starts_with("//") => path.to_string(),
        _ => "/".to_string(),
    };
    let confirm_query = |outcome: &str| -> String {
        // The base is only a carrier for the query encoder; it always parses.
        let Ok(mut url) = reqwest::Url::parse("http://placeholder.invalid/") else {
            return String::new();
        };
        url.query_pairs_mut()
            .append_pair("registration_id", &reference)
            .append_pair("outcome", outcome)
            .append_pair("return_to", &return_to);
        url.query().unwrap_or("").to_string()
    };
    let success_url = format!(
        "{site_url}/registration-confirmed.html?{}",
        confirm_query("succeeded")
    );
    let cancel_url = format!(
        "{site_url}/registration-confirmed.html?{}",
        confirm_query("cancelled")
    );

    // A tenant with no connection is on the mock walkthrough, never a
    // misconfiguration to refuse. success_url/cancel_url
    // belong to this walkthrough only — an embedded session redirects nowhere.
    let checkout_url =
        checkout::mock_checkout_session(&reference, &success_url, &cancel_url, site_url);
    respond(
        200,
        "application/json",
        &json!({"checkout_url": checkout_url, "registration_id": reference}).to_string(),
    )
}

/// The failure reason a Payment records when its registration lost the event's last seat.
const EVENT_FULL_REASON: &str = "event_full";

/// The seat check of POST /registrations, made again once its Payment and Registration are
/// written: the first check and these writes are seconds apart (a Stripe session opens in
/// between), so two guests can both pass it for the last seat. When the event now holds more
/// registrations than seats, this one's Payment fails, which gives its seat back, and the answer
/// is the 409 of a full event. When both racers see the overflow both give their seat back,
/// which leaves a seat open rather than one too many taken.
async fn give_back_an_oversold_seat(
    reference: &str,
    event_slug: &str,
    processor: &str,
    host: Host<'_>,
    payments: &PaymentsProvider,
) -> Option<Value> {
    let Host {
        client,
        wasm_path,
        config,
        ..
    } = host;
    let read = match dispatch::read(client, wasm_path).await {
        Ok(r) => r,
        Err(e) => return Some(respond(500, "text/plain", &format!("{e:#}"))),
    };
    let events = instances_for(
        &read,
        &crate::commerce_ir::registrations_binding(&config.domain).event_prefix(),
    );
    let capacity = events
        .iter()
        .find(|(id, _)| id == event_slug)
        .and_then(|(_, event)| event_capacity(event))?;
    let taken = seats_taken(&read, &config.domain, payments, event_slug);
    if taken as i64 <= capacity {
        return None;
    }
    let facts = json!({
        "reference": {"value": reference},
        "reason": {"value": EVENT_FULL_REASON},
        "reported_processor": {"value": processor},
    });
    if let Err(e) =
        dispatch::handle_routed(host, &payments.failed, json!(reference), facts, None).await
    {
        return Some(respond(500, "text/plain", &format!("{e:#}")));
    }
    Some(respond(
        409,
        "application/json",
        &json!({"error": "this event is full"}).to_string(),
    ))
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

/// Whether a Checkout Session collected what its Payment asked for: Stripe reports it `paid`, for
/// the Payment's amount, in its currency. A session paid by a delayed method (a bank debit)
/// completes `unpaid` and is settled later by `checkout.session.async_payment_succeeded`.
fn session_collected(session: &Value, payment: Option<&Value>) -> bool {
    let Some(amount) = payment.and_then(|p| p.get("amount")) else {
        return false;
    };
    let lower = |v: Option<&Value>| v.and_then(Value::as_str).map(str::to_lowercase);
    let asked_currency =
        lower(amount.get("currency")).unwrap_or_else(|| checkout::CURRENCY.to_string());
    let paid = session.get("payment_status").and_then(Value::as_str) == Some("paid");
    let asked_cents = amount.get("cents").and_then(Value::as_i64);
    paid && asked_cents.is_some()
        && session.get("amount_total").and_then(Value::as_i64) == asked_cents
        && lower(session.get("currency")) == Some(asked_currency)
}

/// What one Checkout Session event settles, as the port operation and its facts. A session that
/// collected the Payment's money succeeds it; one that expired, or whose delayed payment failed,
/// fails it. A session not yet paid, or paid a sum other than the Payment's, settles nothing: the
/// mismatch is logged for the business to reconcile. A mock walkthrough payment settles on the
/// event alone, since the mock webhook carries no amounts and the walkthrough charges nothing.
fn settlement<'a>(
    event_type: &str,
    session: &Value,
    payment: Option<&Value>,
    reference_fact: &Value,
    reported_processor: &Value,
    payments: &'a PaymentsProvider,
) -> Option<(&'a str, Value)> {
    let fail = |reason: &str| {
        Some((
            payments.failed.as_str(),
            json!({"reference": reference_fact, "reason": {"value": reason}, "reported_processor": reported_processor}),
        ))
    };
    match event_type {
        "checkout.session.completed" | "checkout.session.async_payment_succeeded" => {
            let walkthrough = reported_processor["value"] == MOCK_PROCESSOR;
            if !walkthrough && !session_collected(session, payment) {
                if session.get("payment_status").and_then(Value::as_str) == Some("paid") {
                    eprintln!(
                        "webhook: a paid Checkout Session does not match its Payment's amount, so it was not settled: {}",
                        reference_fact["value"]
                    );
                }
                return None;
            }
            // The PaymentIntent id when one exists, else the Checkout
            // Session's own id — `.get`, not a panic, since a synthetic
            // test payload carries no payment_intent at all.
            let transaction_id = session
                .get("payment_intent")
                .and_then(|v| v.as_str())
                .or_else(|| session.get("id").and_then(|v| v.as_str()))
                .unwrap_or("")
                .to_string();
            Some((
                payments.succeeded.as_str(),
                json!({
                    "reference": reference_fact,
                    "transaction_id": {"value": transaction_id},
                    "reported_processor": reported_processor,
                }),
            ))
        }
        "checkout.session.expired" => fail(&payments.lapse_reason),
        "checkout.session.async_payment_failed" => fail(ASYNC_PAYMENT_FAILED_REASON),
        _ => None,
    }
}

/// The failure reason a Payment records when the processor reports its delayed payment failed.
const ASYNC_PAYMENT_FAILED_REASON: &str = "async_payment_failed";

/// POST /webhooks/stripe. Verifies the signature against
/// `STRIPE_WEBHOOK_SECRET`, a saved signing secret, or — only while neither
/// is set — the public mock secret, refusing anything only a real processor
/// could have sent.
pub(crate) async fn webhook_route(
    raw_body: &str,
    signature_header: &str,
    platform: &payments::PlatformConfig,
    host: Host<'_>,
    payments: &PaymentsProvider,
) -> Value {
    let Host {
        client, wasm_path, ..
    } = host;
    let now = unix_now();
    // The environment's signing secret and any saved with the business's own
    // keys are all accepted; with none configured only the mock secret is.
    let configured = platform.webhook_secrets();
    if configured.is_empty() && platform.has_real_credentials() {
        // A real key with no signing secret to check events against: the public
        // mock secret must not stand in for it.
        return mock_secret_refused();
    }
    let candidates = if configured.is_empty() {
        vec![MOCK_STRIPE_WEBHOOK_SECRET]
    } else {
        configured
    };
    let tolerance = crate::commerce_ir::checkout_windows_binding().webhook_tolerance;
    let mut verification = Ok(());
    for secret in &candidates {
        verification =
            checkout::verify_signature(raw_body, signature_header, secret, now, tolerance);
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
    let object = event
        .get("data")
        .and_then(|d| d.get("object"))
        .cloned()
        .unwrap_or_else(|| json!({}));
    let reference = object
        .get("metadata")
        .and_then(|m| m.get("registration_id"))
        .and_then(|v| v.as_str())
        .map(String::from);

    if let Some(reference) = reference {
        // Defaults to "stripe" when there's no matching Payment.
        let processor =
            payment_processor(&read, payments, &reference).unwrap_or_else(|| "stripe".to_string());
        if fallback_secret && processor != MOCK_PROCESSOR {
            return refuse_fallback();
        }
        let reported_processor = json!({"value": processor});
        // The kernel refuses a flat `{"reference": ...}` for an
        // aggregate-scoped port operation — `to` is the bare reference
        // string, and `reference` stays inside `with:` too, since the
        // argument parser still expects to find it in facts.
        let reference_fact = json!({"value": reference.clone()});
        let payment = instances_for(&read, &payments.instance_prefix())
            .into_iter()
            .find(|(id, _)| *id == reference)
            .map(|(_, payment)| payment);
        let verb_and_facts = settlement(
            event_type,
            &object,
            payment.as_ref(),
            &reference_fact,
            &reported_processor,
            payments,
        );

        if let Some((verb, facts)) = verb_and_facts {
            // A refusal here (e.g. a redelivered webhook — Stripe's delivery
            // is at-least-once) is a benign no-op: the payment already holds
            // the right status, and 200 tells Stripe's retry logic to stop.
            match dispatch::handle_routed(host, verb, json!(reference), facts, None).await {
                Err(e) => return respond(500, "text/plain", &format!("{e:#}")),
                // Only the delivery that settles the payment sends the receipt;
                // a redelivery is refused and stays quiet.
                Ok(settled) if settled.accepted && verb == payments.succeeded => {
                    super::registration_receipt::deliver_receipt(&reference, host, payments).await;
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
        LineageConfig {
            domain: "CheckoutFixture".to_string(),
            era: Some(era),
            mirrored: None,
        }
    }

    // A request with no Stripe signature and no cookies.
    fn no_request() -> CheckoutRequest<'static> {
        static NO_COOKIES: std::sync::LazyLock<HashMap<String, String>> =
            std::sync::LazyLock::new(HashMap::new);
        CheckoutRequest {
            stripe_signature: "",
            cookies: &NO_COOKIES,
        }
    }

    fn checkout_wasm_path() -> std::path::PathBuf {
        std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../dist/checkout_fixture.wasm")
    }

    async fn schedule_event(
        client: &Mutex<Client>,
        wasm_path: &Path,
        config: &LineageConfig,
        slug: &str,
        price_cents: i64,
    ) {
        let args = json!({
            "slug": {"value": slug}, "name": {"value": "Sample Studio"},
            "price": {"cents": price_cents}, "capacity": {"value": 20},
        });
        let outcome = dispatch::handle(
            Host::new(client, wasm_path, config, &lambda_client::NeverInvoker),
            "CheckoutFixture::Event.Schedule",
            args,
            None,
        )
        .await
        .unwrap();
        assert!(
            outcome.accepted,
            "scheduling the fixture event should succeed: {:?}",
            outcome.result
        );
    }

    fn sign_stripe_header(secret: &str, now: i64, payload: &str) -> String {
        use hmac::{Hmac, Mac};
        use sha2::Sha256;
        use std::fmt::Write;
        let mut mac = Hmac::<Sha256>::new_from_slice(secret.as_bytes()).unwrap();
        mac.update(format!("{now}.{payload}").as_bytes());
        let digest = mac
            .finalize()
            .into_bytes()
            .iter()
            .fold(String::new(), |mut hex, b| {
                let _ = write!(hex, "{b:02x}"); // writing to a String cannot fail
                hex
            });
        format!("t={now},v1={digest}")
    }

    fn now_secs() -> i64 {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs() as i64
    }

    // A read of the domain: one `yoga` event of `capacity` seats, one `other`
    // event, and a Registration plus same-reference Payment per row, each as
    // (reference, event slug, payment status).
    fn read_with(capacity: i64, rows: &[(&str, &str, &str)]) -> Value {
        let mut instances = serde_json::Map::new();
        instances.insert(
            "CheckoutFixture::Event#yoga".into(),
            json!({"capacity": {"value": capacity}}),
        );
        instances.insert(
            "CheckoutFixture::Event#other".into(),
            json!({"capacity": {"value": 5}}),
        );
        for (reference, event, status) in rows {
            instances.insert(
                format!("CheckoutFixture::Registration#{reference}"),
                json!({"event_slug": event}),
            );
            instances.insert(
                format!("Payments::Payment#{reference}"),
                json!({"status": status}),
            );
        }
        json!({"instances": instances})
    }

    #[test]
    fn a_registration_holds_a_seat_while_its_payment_is_open_paid_or_being_settled() {
        let payments = four_state_payments();
        let read = read_with(
            10,
            &[
                ("a", "yoga", "pending"),
                ("b", "yoga", "succeeded"),
                ("c", "yoga", "refunding"),
                ("d", "yoga", "disputed"),
            ],
        );
        assert_eq!(seats_taken(&read, "CheckoutFixture", &payments, "yoga"), 4);
        assert_eq!(
            seats_left(&read, "CheckoutFixture", &payments, "yoga"),
            Some(6)
        );
    }

    #[test]
    fn a_failed_refunded_or_charged_back_payment_gives_its_seat_back() {
        let payments = crate::commerce_ir::fixture_payments();
        let read = read_with(
            3,
            &[
                ("a", "yoga", "failed"),
                ("b", "yoga", "refunded"),
                ("c", "yoga", "charged_back"),
                ("d", "yoga", "succeeded"),
            ],
        );
        assert_eq!(seats_taken(&read, "CheckoutFixture", &payments, "yoga"), 1);
        assert_eq!(
            seats_left(&read, "CheckoutFixture", &payments, "yoga"),
            Some(2)
        );
    }

    #[test]
    fn seats_are_counted_per_event_and_a_registration_without_a_payment_holds_none() {
        let payments = crate::commerce_ir::fixture_payments();
        let mut read = read_with(
            4,
            &[("a", "yoga", "succeeded"), ("b", "other", "succeeded")],
        );
        read["instances"]["CheckoutFixture::Registration#orphan"] = json!({"event_slug": "yoga"});
        assert_eq!(
            seats_taken(&read, "CheckoutFixture", &payments, "yoga"),
            1,
            "only this event's registrations, and only those with a payment"
        );
        assert_eq!(seats_taken(&read, "CheckoutFixture", &payments, "other"), 1);
    }

    #[test]
    fn an_archived_registration_gives_its_seat_back_whatever_its_payment_says() {
        let payments = crate::commerce_ir::fixture_payments();
        let mut read = read_with(
            3,
            &[
                ("a", "yoga", "succeeded"),
                ("b", "yoga", "pending"),
                ("c", "yoga", "succeeded"),
            ],
        );
        assert_eq!(seats_taken(&read, "CheckoutFixture", &payments, "yoga"), 3);
        read["instances"]["CheckoutFixture::Registration#a"]["status"] = json!("archived");
        assert_eq!(
            seats_taken(&read, "CheckoutFixture", &payments, "yoga"),
            2,
            "a paid but archived registration frees its seat"
        );
        assert_eq!(
            seats_left(&read, "CheckoutFixture", &payments, "yoga"),
            Some(1)
        );
    }

    fn binding_freeing(states: &[&str]) -> crate::commerce_ir::RegistrationsProvider {
        let mut binding =
            crate::commerce_ir::RegistrationsProvider::conventional("CheckoutFixture");
        binding.frees_seat = states
            .iter()
            .map(std::string::ToString::to_string)
            .collect();
        binding
    }

    #[test]
    fn a_declared_state_other_than_archived_frees_its_seat() {
        let payments = crate::commerce_ir::fixture_payments();
        let mut read = read_with(3, &[("a", "yoga", "succeeded"), ("b", "yoga", "succeeded")]);
        set_registration_status(&mut read, "a", "cancelled");
        let counts = count_seats(&read, &binding_freeing(&["cancelled"]), &payments);
        assert_eq!(
            counts.get("yoga"),
            Some(&1),
            "cancelled is declared, so it frees the seat"
        );
    }

    #[test]
    fn the_fixture_declared_cancelled_state_frees_its_seat_beside_archived() {
        let payments = crate::commerce_ir::fixture_payments();
        let binding = crate::commerce_ir::registrations_provider(&crate::commerce_ir::fixture_ir())
            .expect("registrations");
        let mut read = read_with(
            3,
            &[
                ("a", "yoga", "succeeded"),
                ("b", "yoga", "succeeded"),
                ("c", "yoga", "succeeded"),
            ],
        );
        set_registration_status(&mut read, "a", "cancelled");
        set_registration_status(&mut read, "b", "archived");
        assert_eq!(
            count_seats(&read, &binding, &payments).get("yoga"),
            Some(&1)
        );
    }

    #[test]
    fn a_state_the_chapter_does_not_declare_keeps_its_seat_even_when_it_is_archived() {
        let payments = crate::commerce_ir::fixture_payments();
        let mut read = read_with(3, &[("a", "yoga", "succeeded")]);
        set_registration_status(&mut read, "a", "archived");
        let counts = count_seats(&read, &binding_freeing(&["cancelled"]), &payments);
        assert_eq!(
            counts.get("yoga"),
            Some(&1),
            "only the declared states free a seat"
        );
    }

    #[test]
    fn with_no_declaration_the_conventional_binding_frees_the_archived_seat() {
        let payments = crate::commerce_ir::fixture_payments();
        let mut read = read_with(3, &[("a", "yoga", "succeeded")]);
        set_registration_status(&mut read, "a", "archived");
        let conventional =
            crate::commerce_ir::RegistrationsProvider::conventional("CheckoutFixture");
        assert_eq!(
            count_seats(&read, &conventional, &payments).get("yoga"),
            None
        );
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
        assert_eq!(
            seats_taken(&read, "CheckoutFixture", &payments, "yoga"),
            2,
            "a null status is not archived either"
        );
    }

    #[test]
    fn a_restored_registration_takes_its_seat_back() {
        let payments = crate::commerce_ir::fixture_payments();
        let mut read = read_with(2, &[("a", "yoga", "succeeded")]);
        read["instances"]["CheckoutFixture::Registration#a"]["status"] = json!("archived");
        assert_eq!(
            seats_left(&read, "CheckoutFixture", &payments, "yoga"),
            Some(2)
        );
        read["instances"]["CheckoutFixture::Registration#a"]["status"] = json!("active");
        assert_eq!(
            seats_left(&read, "CheckoutFixture", &payments, "yoga"),
            Some(1)
        );
    }

    #[test]
    fn seats_left_with_mixed_statuses_counts_only_the_active_holders() {
        let payments = crate::commerce_ir::fixture_payments();
        let mut read = read_with(
            6,
            &[
                ("a", "yoga", "succeeded"),
                ("b", "yoga", "succeeded"),
                ("c", "yoga", "pending"),
                ("d", "yoga", "failed"),
                ("e", "other", "succeeded"),
            ],
        );
        read["instances"]["CheckoutFixture::Registration#a"]["status"] = json!("archived");
        read["instances"]["CheckoutFixture::Registration#b"]["status"] = json!("active");
        read["instances"]["CheckoutFixture::Registration#d"]["status"] = json!("active");
        read["instances"]["CheckoutFixture::Registration#e"]["status"] = json!("archived");
        // b (active, paid) and c (no status, pending) hold; a is archived, d's
        // payment failed, and e is another event's.
        assert_eq!(seats_taken(&read, "CheckoutFixture", &payments, "yoga"), 2);
        assert_eq!(
            seats_left(&read, "CheckoutFixture", &payments, "yoga"),
            Some(4)
        );
        assert_eq!(
            seats_left(&read, "CheckoutFixture", &payments, "other"),
            Some(5),
            "the archived registration on `other` frees its seat"
        );
    }

    #[test]
    fn seats_left_never_goes_below_zero_and_is_none_without_an_event_or_capacity() {
        let payments = crate::commerce_ir::fixture_payments();
        let oversold = read_with(1, &[("a", "yoga", "succeeded"), ("b", "yoga", "succeeded")]);
        assert_eq!(
            seats_left(&oversold, "CheckoutFixture", &payments, "yoga"),
            Some(0)
        );
        assert_eq!(
            seats_left(&oversold, "CheckoutFixture", &payments, "nowhere"),
            None
        );
        let no_capacity =
            json!({"instances": {"CheckoutFixture::Event#yoga": {"name": {"value": "Yoga"}}}});
        assert_eq!(
            seats_left(&no_capacity, "CheckoutFixture", &payments, "yoga"),
            None
        );
    }

    // The site's own JavaScript tests of this rule (its seat-count spec) use the
    // fixtures below; the same cases run here so the two counts cannot drift.
    const HOLDING: [&str; 4] = ["pending", "succeeded", "refunding", "disputed"];
    const FREEING: [&str; 3] = ["failed", "refunded", "charged_back"];

    fn set_registration_status(read: &mut Value, reference: &str, status: &str) {
        read["instances"][format!("CheckoutFixture::Registration#{reference}")]["status"] =
            json!(status);
    }

    /// The fixture's payments binding with the production table: the fixture lifecycle has only
    /// pending, succeeded and failed, so refunding and disputed need the table set here.
    fn four_state_payments() -> crate::commerce_ir::PaymentsProvider {
        let mut payments = crate::commerce_ir::fixture_payments();
        payments.holds_seat = HOLDING
            .iter()
            .map(std::string::ToString::to_string)
            .collect();
        payments
    }

    #[test]
    fn the_seat_holding_table_comes_from_the_fixture_ir_mark() {
        assert_eq!(
            crate::commerce_ir::fixture_payments().holds_seat,
            vec!["pending", "succeeded"]
        );
    }

    #[test]
    fn every_holding_status_holds_one_seat_and_every_freeing_status_holds_none() {
        let payments = four_state_payments();
        for status in HOLDING {
            let read = read_with(10, &[("r", "yoga", status)]);
            assert_eq!(
                seats_taken(&read, "CheckoutFixture", &payments, "yoga"),
                1,
                "{status} should hold a seat"
            );
        }
        for status in FREEING {
            let read = read_with(10, &[("r", "yoga", status)]);
            assert_eq!(
                seats_taken(&read, "CheckoutFixture", &payments, "yoga"),
                0,
                "{status} should free the seat"
            );
        }
    }

    #[test]
    fn a_reference_reads_as_a_plain_id_or_a_wrapped_value_and_counts_per_event() {
        let payments = crate::commerce_ir::fixture_payments();
        let mut read = read_with(
            10,
            &[
                ("a", "yoga", "succeeded"),
                ("b", "yoga", "pending"),
                ("c", "other", "pending"),
                ("d", "yoga", "failed"),
            ],
        );
        read["instances"]["CheckoutFixture::Registration#b"]["event_slug"] =
            json!({"value": "yoga"});
        assert_eq!(seats_taken(&read, "CheckoutFixture", &payments, "yoga"), 2);
        assert_eq!(seats_taken(&read, "CheckoutFixture", &payments, "other"), 1);
        read["instances"]["CheckoutFixture::Registration#a"]["event_slug"] = json!("");
        assert_eq!(
            seats_taken(&read, "CheckoutFixture", &payments, "yoga"),
            1,
            "an empty event id is no reference"
        );
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
            assert_eq!(
                seats_taken(&read, "CheckoutFixture", &payments, "yoga"),
                0,
                "archived + {status} should not hold a seat"
            );
        }
    }

    #[test]
    fn archiving_one_of_several_guests_frees_exactly_one_seat() {
        let payments = crate::commerce_ir::fixture_payments();
        let mut read = read_with(
            10,
            &[
                ("a", "yoga", "succeeded"),
                ("b", "yoga", "succeeded"),
                ("c", "yoga", "pending"),
            ],
        );
        set_registration_status(&mut read, "a", "active");
        set_registration_status(&mut read, "b", "archived");
        set_registration_status(&mut read, "c", "active");
        assert_eq!(seats_taken(&read, "CheckoutFixture", &payments, "yoga"), 2);
    }

    #[test]
    fn seat_figures_carry_capacity_taken_and_left_and_null_without_a_capacity() {
        let payments = crate::commerce_ir::fixture_payments();
        let read = read_with(
            3,
            &[
                ("a", "yoga", "succeeded"),
                ("b", "yoga", "pending"),
                ("c", "yoga", "succeeded"),
                ("d", "yoga", "succeeded"),
            ],
        );
        assert_eq!(
            one_seat_figures(&read, "CheckoutFixture", &payments, "yoga"),
            Some(json!({"slug": "yoga", "capacity": 3, "seats_taken": 4, "seats_left": 0}))
        );
        assert_eq!(
            one_seat_figures(&read, "CheckoutFixture", &payments, "nowhere"),
            None
        );
        assert_eq!(
            all_seat_figures(&read, "CheckoutFixture", &payments),
            json!({"events": {
                "yoga": {"capacity": 3, "seats_taken": 4, "seats_left": 0},
                "other": {"capacity": 5, "seats_taken": 0, "seats_left": 5},
            }})
        );
        let no_capacity =
            json!({"instances": {"CheckoutFixture::Event#yoga": {"name": {"value": "Yoga"}}}});
        assert_eq!(
            one_seat_figures(&no_capacity, "CheckoutFixture", &payments, "yoga"),
            Some(json!({"slug": "yoga", "capacity": null, "seats_taken": 0, "seats_left": null}))
        );
    }

    #[test]
    fn the_seat_figures_agree_with_seats_left_for_every_event() {
        let payments = crate::commerce_ir::fixture_payments();
        let mut read = read_with(
            6,
            &[
                ("a", "yoga", "succeeded"),
                ("b", "yoga", "refunding"),
                ("c", "other", "pending"),
                ("d", "yoga", "failed"),
            ],
        );
        set_registration_status(&mut read, "b", "archived");
        let all = all_seat_figures(&read, "CheckoutFixture", &payments);
        for slug in ["yoga", "other"] {
            assert_eq!(
                all["events"][slug]["seats_left"].as_i64(),
                seats_left(&read, "CheckoutFixture", &payments, slug),
                "{slug}"
            );
            assert_eq!(
                all["events"][slug]["seats_taken"].as_u64(),
                Some(seats_taken(&read, "CheckoutFixture", &payments, slug) as u64),
                "{slug}"
            );
        }
    }

    #[test]
    fn only_a_single_segment_slug_between_events_and_seats_names_an_event() {
        assert_eq!(seats_path_slug("/events/yoga/seats"), Some("yoga"));
        for path in [
            "/events/seats",
            "/events//seats",
            "/events/a/b/seats",
            "/events/yoga",
            "/events/yoga/seats/x",
            "/registrations/x/seats",
        ] {
            assert_eq!(seats_path_slug(path), None, "{path}");
        }
    }

    #[tokio::test]
    async fn the_seat_routes_answer_from_a_real_read_and_404_an_unknown_event() {
        let client = scratch_db("hecks_host_web_test_seat_routes").await;
        provision_lineage(
            &*client.lock().await,
            "CheckoutFixture",
            1,
            &["Event", "Registration", "Payment"],
        )
        .await;
        let config = checkout_config(1);
        let wasm_path = checkout_wasm_path();
        schedule_event(&client, &wasm_path, &config, "yoga", 4200).await;
        let ir = crate::commerce_ir::fixture_ir();
        let get = |path: &'static str| {
            let (client, wasm_path, config, ir) = (&client, &wasm_path, &config, &ir);
            async move {
                let response = payments_routes(
                    Some(ir),
                    "GET",
                    path,
                    "",
                    &no_request(),
                    Host::new(client, wasm_path, config, &lambda_client::NeverInvoker),
                )
                .await
                .expect("a seats path");
                (
                    response["statusCode"].as_u64().unwrap(),
                    serde_json::from_str::<Value>(response["body"].as_str().unwrap()).unwrap(),
                )
            }
        };
        assert_eq!(
            get("/events/yoga/seats").await,
            (
                200,
                json!({"slug": "yoga", "capacity": 20, "seats_taken": 0, "seats_left": 20})
            )
        );
        assert_eq!(
            get("/events/seats").await,
            (
                200,
                json!({"events": {"yoga": {"capacity": 20, "seats_taken": 0, "seats_left": 20}}})
            )
        );
        assert_eq!(
            get("/events/nowhere/seats").await,
            (404, json!({"error": "no such event"}))
        );
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

        assert_eq!(
            attendee.get("event_slug"),
            None,
            "routing metadata must not leak into Attendee"
        );
        assert_eq!(
            attendee.get("return_to"),
            None,
            "routing metadata must not leak into Attendee"
        );
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
        assert_eq!(
            attendee_from(&body),
            json!({"name": "Ada Lovelace", "email": "ada@example.com"})
        );
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
        assert_eq!(
            display_name_from(&json!({"email": "ada@example.com"})),
            None
        );
        assert_eq!(
            display_name_from(&json!({"first_name": "Ada"})),
            None,
            "last_name alone is missing"
        );
        assert_eq!(
            display_name_from(&json!({"last_name": "Lovelace"})),
            None,
            "first_name alone is missing"
        );
    }

    #[tokio::test]
    async fn registrations_route_refuses_a_body_missing_any_required_field() {
        let client = scratch_db("hecks_host_web_test_registrations_missing_fields").await;
        provision_lineage(
            &*client.lock().await,
            "CheckoutFixture",
            1,
            &["Event", "Registration", "Payment"],
        )
        .await;

        let response = registrations_route(
            r#"{"event_slug":"yoga-aug"}"#,
            &payments::test_platform(),
            Host::new(
                &client,
                &checkout_wasm_path(),
                &checkout_config(1),
                &lambda_client::NeverInvoker,
            ),
            &crate::commerce_ir::fixture_payments(),
        )
        .await;
        assert_eq!(response["statusCode"], 400);
        assert!(response["body"].as_str().unwrap().contains("missing name"));
    }

    // A caller submits `first_name`/`last_name` against CheckoutFixture's
    // `name`-only Attendee — proves display_name_from composes a real Client
    // name and attendee_from forwards fields verbatim, without a second fixture.
    #[tokio::test]
    async fn registrations_route_forwards_a_new_shaped_attendee_verbatim_even_against_an_old_shaped_fixture(
    ) {
        let client = scratch_db("hecks_host_web_test_registrations_new_shape").await;
        provision_lineage(
            &*client.lock().await,
            "CheckoutFixture",
            1,
            &["Event", "Registration", "Payment"],
        )
        .await;
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
        let response = registrations_route(
            &body,
            &payments::test_platform(),
            Host::new(&client, &wasm_path, &config, &lambda_client::NeverInvoker),
            &crate::commerce_ir::fixture_payments(),
        )
        .await;

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
            instances
                .keys()
                .all(|k| !k.starts_with("CheckoutFixture::Registration#")),
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
                let response = payments_routes(
                    ir,
                    method,
                    path,
                    "not json",
                    &no_request(),
                    Host::new(&client, &wasm_path, &config, &lambda_client::NeverInvoker),
                )
                .await;
                assert!(
                    response.is_none(),
                    "{method} {path} answered although the IR declares no payments: {response:?}"
                );
            }
        }

        let fixture_ir = crate::commerce_ir::fixture_ir();
        let response = payments_routes(
            Some(&fixture_ir),
            "POST",
            "/registrations",
            "not json",
            &no_request(),
            Host::new(&client, &wasm_path, &config, &lambda_client::NeverInvoker),
        )
        .await;
        assert_eq!(
            response.expect("the fixture IR declares payments, so the route answers")["statusCode"],
            400
        );
    }

    #[tokio::test]
    async fn registrations_route_refuses_invalid_json_outright() {
        let client = scratch_db("hecks_host_web_test_registrations_bad_json").await;
        provision_lineage(
            &*client.lock().await,
            "CheckoutFixture",
            1,
            &["Event", "Registration", "Payment"],
        )
        .await;

        let response = registrations_route(
            "not json",
            &payments::test_platform(),
            Host::new(
                &client,
                &checkout_wasm_path(),
                &checkout_config(1),
                &lambda_client::NeverInvoker,
            ),
            &crate::commerce_ir::fixture_payments(),
        )
        .await;
        assert_eq!(response["statusCode"], 400);
    }

    const EVENTS_SECRET: &str = "s3cret";
    const EVENTS_ADMIN: &str = "admin@example.com";
    const EVENTS_MEMBER: &str = "member@example.com";

    // A scratch database with the fixture's lineage and a membership table holding one Admin
    // and one Member, and the domain IR that names that membership.
    async fn events_db(name: &str) -> (Mutex<Client>, Value) {
        let client = scratch_db(name).await;
        {
            let guard = client.lock().await;
            provision_lineage(
                &guard,
                "CheckoutFixture",
                1,
                &["Event", "Registration", "Payment"],
            )
            .await;
            guard
                .batch_execute(
                    "CREATE TABLE acme_member_head_snapshot_1 (id text PRIMARY KEY, ordinal bigint NOT NULL, state jsonb NOT NULL);
                     CREATE VIEW acme_member_head AS SELECT id, state FROM acme_member_head_snapshot_1;",
                )
                .await
                .unwrap();
            for (email, role) in [(EVENTS_ADMIN, "Admin"), (EVENTS_MEMBER, "Member")] {
                let state = json!({"email": {"value": email}, "role": {"value": role}});
                guard
                    .execute(
                        "INSERT INTO acme_member_head_snapshot_1 (id, ordinal, state) VALUES ($1, 0, $2::jsonb)",
                        &[&email, &state],
                    )
                    .await
                    .unwrap();
            }
        }
        let domain_ir = json!({
            "name": "Acme",
            "lineage": {"capable_aggregates": [{"name": "Member", "storage_name": "member"}]},
            "membership": {"provider": "Acme", "aggregate": "Acme::Member"},
        });
        (client, domain_ir)
    }

    // The cookies of a signed-in `email`, or none.
    fn events_cookies(email: Option<&str>) -> HashMap<String, String> {
        email
            .map(|email| {
                (
                    crate::auth::account_cookie_name(),
                    crate::auth::account_token(EVENTS_SECRET, email, 60),
                )
            })
            .into_iter()
            .collect()
    }

    // POST /events as `email` (none: no account cookie).
    async fn post_event(
        client: &Mutex<Client>,
        domain_ir: &Value,
        email: Option<&str>,
        body: &str,
    ) -> Value {
        events_route(
            body,
            domain_ir,
            &events_cookies(email),
            EVENTS_SECRET,
            Host::new(
                client,
                &checkout_wasm_path(),
                &checkout_config(1),
                &lambda_client::NeverInvoker,
            ),
        )
        .await
    }

    fn event_keys(read: &Value) -> Vec<String> {
        read["instances"]
            .as_object()
            .unwrap()
            .keys()
            .filter(|k| k.starts_with("CheckoutFixture::Event#"))
            .cloned()
            .collect()
    }

    // A guest, a forged cookie and a signed-in Member are all refused before anything is read
    // or written: scheduling (and so pricing) a bookable event is an Admin's or Owner's.
    #[tokio::test]
    async fn events_route_schedules_nothing_for_anyone_but_an_active_admin() {
        let (client, domain_ir) = events_db("hecks_host_web_test_events_auth").await;
        let body = json!({"slug": "squat", "name": "Squatted", "price_cents": 1, "capacity": 999})
            .to_string();

        let guest = post_event(&client, &domain_ir, None, &body).await;
        assert_eq!(guest["statusCode"], 401, "{guest:?}");
        let member = post_event(&client, &domain_ir, Some(EVENTS_MEMBER), &body).await;
        assert_eq!(member["statusCode"], 403, "{member:?}");
        let mut forged = HashMap::new();
        forged.insert(
            crate::auth::account_cookie_name(),
            crate::auth::account_token("another-secret", EVENTS_ADMIN, 60),
        );
        let forged = events_route(
            &body,
            &domain_ir,
            &forged,
            EVENTS_SECRET,
            Host::new(
                &client,
                &checkout_wasm_path(),
                &checkout_config(1),
                &lambda_client::NeverInvoker,
            ),
        )
        .await;
        assert_eq!(forged["statusCode"], 401, "{forged:?}");

        let read = dispatch::read(&client, &checkout_wasm_path())
            .await
            .unwrap();
        assert!(
            event_keys(&read).is_empty(),
            "a refused caller scheduled an event"
        );
    }

    #[tokio::test]
    async fn events_route_refuses_invalid_json_outright() {
        let (client, domain_ir) = events_db("hecks_host_web_test_events_bad_json").await;
        let response = post_event(&client, &domain_ir, Some(EVENTS_ADMIN), "not json").await;
        assert_eq!(response["statusCode"], 400);
    }

    #[tokio::test]
    async fn events_route_refuses_a_body_missing_any_required_field() {
        let (client, domain_ir) = events_db("hecks_host_web_test_events_missing_fields").await;
        let response = post_event(
            &client,
            &domain_ir,
            Some(EVENTS_ADMIN),
            r#"{"slug":"new-event"}"#,
        )
        .await;
        assert_eq!(response["statusCode"], 400);
        assert!(response["body"].as_str().unwrap().contains("missing name"));
    }

    #[tokio::test]
    async fn events_route_schedules_a_new_event_and_returns_201() {
        let (client, domain_ir) = events_db("hecks_host_web_test_events_new").await;
        let body = json!({"slug": "mock-payments-event", "name": "Mock Payments Event", "price_cents": 4200, "capacity": 20}).to_string();
        let response = post_event(&client, &domain_ir, Some(EVENTS_ADMIN), &body).await;
        assert_eq!(response["statusCode"], 201, "{response:?}");
        let response_body: Value =
            serde_json::from_str(response["body"].as_str().unwrap()).unwrap();
        assert_eq!(response_body["slug"]["value"], "mock-payments-event");
        assert_eq!(response_body["name"]["value"], "Mock Payments Event");
        assert_eq!(response_body["price"]["cents"], 4200);
        assert_eq!(response_body["capacity"]["value"], 20);
        assert_eq!(response_body["status"], "open");

        let read = dispatch::read(&client, &checkout_wasm_path())
            .await
            .unwrap();
        assert_eq!(
            event_keys(&read),
            vec!["CheckoutFixture::Event#mock-payments-event".to_string()],
            "Event.Schedule should have committed for real"
        );
    }

    // A repeat call with the same fields is a 200 answering the existing event; one with other
    // fields is a 409 and changes nothing, so an early call cannot fix a slug's price.
    #[tokio::test]
    async fn events_route_answers_a_matching_repeat_and_refuses_a_different_one() {
        let (client, domain_ir) = events_db("hecks_host_web_test_events_idempotent").await;
        let body = json!({"slug": "repeat-event", "name": "Repeat Event", "price_cents": 1000, "capacity": 5}).to_string();
        let first = post_event(&client, &domain_ir, Some(EVENTS_ADMIN), &body).await;
        assert_eq!(first["statusCode"], 201, "{first:?}");

        let again = post_event(&client, &domain_ir, Some(EVENTS_ADMIN), &body).await;
        assert_eq!(again["statusCode"], 200, "{again:?}");
        let different = json!({"slug": "repeat-event", "name": "Different Name", "price_cents": 9999, "capacity": 1}).to_string();
        let refused = post_event(&client, &domain_ir, Some(EVENTS_ADMIN), &different).await;
        assert_eq!(refused["statusCode"], 409, "{refused:?}");

        let read = dispatch::read(&client, &checkout_wasm_path())
            .await
            .unwrap();
        assert_eq!(
            event_keys(&read).len(),
            1,
            "exactly one Event, never a second dispatch"
        );
        let event = &read["instances"]["CheckoutFixture::Event#repeat-event"];
        assert_eq!(
            event["price"]["cents"], 1000,
            "the refused repeat changed the price"
        );
    }

    // The registration id rides in the pay and confirmation URLs (and so in Referer headers), so
    // whoever holds it may read the registration back, but never the attendee's contact details.
    #[tokio::test]
    async fn the_registration_read_back_by_id_carries_no_email_or_phone() {
        let client = scratch_db("hecks_host_web_test_registration_show").await;
        provision_lineage(
            &*client.lock().await,
            "CheckoutFixture",
            1,
            &["Event", "Registration", "Payment"],
        )
        .await;
        let (config, wasm_path) = (checkout_config(1), checkout_wasm_path());
        schedule_event(&client, &wasm_path, &config, "show-event", 4200).await;
        let body =
            json!({"event_slug": "show-event", "name": "Ada Lovelace", "email": "ada@example.com"});
        let registered = registrations_route(
            &body.to_string(),
            &payments::test_platform(),
            Host::new(&client, &wasm_path, &config, &lambda_client::NeverInvoker),
            &crate::commerce_ir::fixture_payments(),
        )
        .await;
        let registered: Value = serde_json::from_str(registered["body"].as_str().unwrap()).unwrap();
        let id = registered["registration_id"]
            .as_str()
            .expect("a registration id");

        let shown = registration_show_route(
            id,
            &client,
            &wasm_path,
            &config,
            &crate::commerce_ir::fixture_payments(),
        )
        .await;
        let shown_body = shown["body"].as_str().unwrap();
        assert_eq!(shown["statusCode"], 200, "{shown:?}");
        assert!(!shown_body.contains("ada@example.com"), "{shown_body}");
        let shown: Value = serde_json::from_str(shown_body).unwrap();
        assert_eq!(
            (
                shown["attendee"].get("email"),
                shown["attendee"].get("phone")
            ),
            (None, None)
        );
        assert_eq!(
            (
                shown["amount_cents"].as_i64(),
                shown["payment_status"].as_str()
            ),
            (Some(4200), Some("pending"))
        );
    }

    #[tokio::test]
    async fn registrations_route_404s_an_unknown_event_slug() {
        let client = scratch_db("hecks_host_web_test_registrations_no_event").await;
        provision_lineage(
            &*client.lock().await,
            "CheckoutFixture",
            1,
            &["Event", "Registration", "Payment"],
        )
        .await;

        let body =
            json!({"event_slug": "nope", "name": "Ada", "email": "ada@example.com"}).to_string();
        let response = registrations_route(
            &body,
            &payments::test_platform(),
            Host::new(
                &client,
                &checkout_wasm_path(),
                &checkout_config(1),
                &lambda_client::NeverInvoker,
            ),
            &crate::commerce_ir::fixture_payments(),
        )
        .await;
        assert_eq!(response["statusCode"], 404);
    }

    #[tokio::test]
    async fn registrations_route_refuses_a_closed_event() {
        let client = scratch_db("hecks_host_web_test_registrations_closed_event").await;
        provision_lineage(
            &*client.lock().await,
            "CheckoutFixture",
            1,
            &["Event", "Registration", "Payment"],
        )
        .await;
        let config = checkout_config(1);
        let wasm_path = checkout_wasm_path();

        schedule_event(&client, &wasm_path, &config, "closed-event", 4200).await;
        let close = dispatch::handle(
            Host::new(&client, &wasm_path, &config, &lambda_client::NeverInvoker),
            "CheckoutFixture::Event.Close",
            json!({"id": "closed-event"}),
            None,
        )
        .await
        .unwrap();
        assert!(
            close.accepted,
            "closing the fixture event should succeed: {:?}",
            close.result
        );

        let body = json!({"event_slug": "closed-event", "name": "Ada", "email": "ada@example.com"})
            .to_string();
        let response = registrations_route(
            &body,
            &payments::test_platform(),
            Host::new(&client, &wasm_path, &config, &lambda_client::NeverInvoker),
            &crate::commerce_ir::fixture_payments(),
        )
        .await;
        assert_eq!(response["statusCode"], 422);
        assert!(response["body"].as_str().unwrap().contains("closed"));
    }

    // Schedules `slug` starting at `starts_at` with the optional cutoff set
    // (or absent), through the real Event.Schedule command.
    async fn schedule_timed_event(
        client: &Mutex<Client>,
        wasm_path: &Path,
        config: &LineageConfig,
        slug: &str,
        starts_at: i64,
        cutoff_hours: Option<i64>,
    ) {
        let mut args = json!({
            "slug": {"value": slug}, "name": {"value": "Sample Studio"},
            "price": {"cents": 4200}, "capacity": {"value": 20},
            "starts_at": {"value": starts_at},
        });
        if let Some(hours) = cutoff_hours {
            args["registration_cutoff_hours"] = json!({"value": hours});
        }
        let outcome = dispatch::handle(
            Host::new(client, wasm_path, config, &lambda_client::NeverInvoker),
            "CheckoutFixture::Event.Schedule",
            args,
            None,
        )
        .await
        .unwrap();
        assert!(
            outcome.accepted,
            "scheduling the timed fixture event should succeed: {:?}",
            outcome.result
        );
    }

    #[tokio::test]
    async fn registrations_route_refuses_a_session_inside_its_registration_cutoff_and_writes_nothing(
    ) {
        let client = scratch_db("hecks_host_web_test_registrations_cutoff_passed").await;
        provision_lineage(
            &*client.lock().await,
            "CheckoutFixture",
            1,
            &["Event", "Registration", "Payment"],
        )
        .await;
        let config = checkout_config(1);
        let wasm_path = checkout_wasm_path();

        // Starts in 5 hours with a 6 hour cutoff: registration closed an hour ago.
        let now = 1_800_000_000;
        schedule_timed_event(
            &client,
            &wasm_path,
            &config,
            "too-late",
            now + 5 * 3600,
            Some(6),
        )
        .await;

        let body = json!({"event_slug": "too-late", "name": "Ada", "email": "ada@example.com"})
            .to_string();
        let response = registrations_route_at(
            &body,
            &payments::test_platform(),
            Host::new(&client, &wasm_path, &config, &lambda_client::NeverInvoker),
            &crate::commerce_ir::fixture_payments(),
            now,
        )
        .await;
        assert_eq!(response["statusCode"], 422, "{response:?}");
        assert_eq!(
            serde_json::from_str::<Value>(response["body"].as_str().unwrap()).unwrap(),
            json!({"error": "registration has closed for this event"})
        );

        let read = dispatch::read(&client, &wasm_path).await.unwrap();
        let instances = read["instances"].as_object().unwrap();
        assert!(
            instances
                .keys()
                .all(|k| !k.starts_with("Payments::Payment#")
                    && !k.starts_with("CheckoutFixture::Registration#")),
            "a refused registration must write no Payment and no Registration: {instances:?}"
        );
    }

    #[tokio::test]
    async fn registrations_route_accepts_a_session_with_no_cutoff_even_when_it_has_a_start() {
        let client = scratch_db("hecks_host_web_test_registrations_cutoff_absent").await;
        provision_lineage(
            &*client.lock().await,
            "CheckoutFixture",
            1,
            &["Event", "Registration", "Payment"],
        )
        .await;
        let config = checkout_config(1);
        let wasm_path = checkout_wasm_path();

        // A start in the past and no cutoff field: nothing to enforce.
        let now = 1_800_000_000;
        schedule_timed_event(&client, &wasm_path, &config, "no-cutoff", now - 3600, None).await;

        let body = json!({"event_slug": "no-cutoff", "name": "Ada", "email": "ada@example.com"})
            .to_string();
        let response = registrations_route_at(
            &body,
            &payments::test_platform(),
            Host::new(&client, &wasm_path, &config, &lambda_client::NeverInvoker),
            &crate::commerce_ir::fixture_payments(),
            now,
        )
        .await;
        assert_eq!(response["statusCode"], 200, "{response:?}");

        let read = dispatch::read(&client, &wasm_path).await.unwrap();
        let instances = read["instances"].as_object().unwrap();
        assert!(
            instances
                .keys()
                .any(|k| k.starts_with("CheckoutFixture::Registration#")),
            "{instances:?}"
        );
        assert!(
            instances
                .keys()
                .any(|k| k.starts_with("Payments::Payment#")),
            "{instances:?}"
        );
    }

    #[test]
    fn a_registration_cutoff_needs_both_fields_and_ignores_unreadable_ones() {
        let now = 1_000_000;
        let past_start = json!({"starts_at": 0});
        assert!(!registration_cutoff_passed(&json!({}), now));
        assert!(
            !registration_cutoff_passed(&past_start, now),
            "a start with no cutoff hours is no cutoff"
        );
        assert!(
            !registration_cutoff_passed(&json!({"registration_cutoff_hours": 48}), now),
            "hours with no start is no cutoff"
        );
        assert!(!registration_cutoff_passed(
            &json!({"starts_at": null, "registration_cutoff_hours": 48}),
            now
        ));
        assert!(!registration_cutoff_passed(
            &json!({"starts_at": 0, "registration_cutoff_hours": null}),
            now
        ));
        assert!(!registration_cutoff_passed(
            &json!({"starts_at": "soon", "registration_cutoff_hours": 48}),
            now
        ));
        assert!(!registration_cutoff_passed(
            &json!({"starts_at": 0, "registration_cutoff_hours": "two"}),
            now
        ));
        assert!(!registration_cutoff_passed(
            &json!({"starts_at": {"value": "soon"}, "registration_cutoff_hours": {"value": 1.5}}),
            now
        ));
    }

    #[test]
    fn a_registration_cutoff_is_open_exactly_at_the_boundary_and_closed_a_second_later() {
        // Cutoff 2 hours before a start of 100_000: the window shuts after 92_800.
        let event = json!({"starts_at": 100_000, "registration_cutoff_hours": 2});
        assert!(!registration_cutoff_passed(&event, 92_799));
        assert!(
            !registration_cutoff_passed(&event, 92_800),
            "exactly at the cutoff is still open"
        );
        assert!(registration_cutoff_passed(&event, 92_801));
    }

    #[test]
    fn a_registration_cutoff_reads_a_value_object_or_a_bare_number() {
        let wrapped =
            json!({"starts_at": {"value": 100_000}, "registration_cutoff_hours": {"value": 2}});
        let bare = json!({"starts_at": 100_000, "registration_cutoff_hours": 2});
        let mixed = json!({"starts_at": {"value": 100_000}, "registration_cutoff_hours": 2});
        for event in [wrapped, bare, mixed] {
            assert!(!registration_cutoff_passed(&event, 92_800), "{event}");
            assert!(registration_cutoff_passed(&event, 92_801), "{event}");
        }
    }

    #[test]
    fn a_registration_cutoff_refuses_a_start_already_in_the_past() {
        let event = json!({"starts_at": 1_000, "registration_cutoff_hours": 1});
        assert!(registration_cutoff_passed(&event, 5_000));
        let no_hours_of_notice = json!({"starts_at": 1_000, "registration_cutoff_hours": 0});
        assert!(!registration_cutoff_passed(&no_hours_of_notice, 1_000));
        assert!(registration_cutoff_passed(&no_hours_of_notice, 1_001));
    }

    #[tokio::test]
    async fn registrations_route_propagates_a_real_domain_refusal_from_payment_initiate() {
        // A zero-price event: PositiveMoney's invariant refuses
        // Payment.Initiate before Registration.Request is ever reached,
        // proving the refusal is the real domain rule.
        let client = scratch_db("hecks_host_web_test_registrations_zero_price").await;
        provision_lineage(
            &*client.lock().await,
            "CheckoutFixture",
            1,
            &["Event", "Registration", "Payment"],
        )
        .await;
        let config = checkout_config(1);
        let wasm_path = checkout_wasm_path();

        schedule_event(&client, &wasm_path, &config, "free-event", 0).await;

        let body = json!({"event_slug": "free-event", "name": "Ada", "email": "ada@example.com"})
            .to_string();
        let response = registrations_route(
            &body,
            &payments::test_platform(),
            Host::new(&client, &wasm_path, &config, &lambda_client::NeverInvoker),
            &crate::commerce_ir::fixture_payments(),
        )
        .await;
        assert_eq!(response["statusCode"], 422);
        assert!(
            response["body"].as_str().unwrap().contains("positive"),
            "should surface PositiveMoney's own invariant text: {response:?}"
        );

        // And neither the payment nor the registration was persisted —
        // Registration.Request must never have been dispatched at all.
        let read = dispatch::read(&client, &wasm_path).await.unwrap();
        let instances = read["instances"].as_object().unwrap();
        assert!(instances
            .keys()
            .all(|k| !k.starts_with("CheckoutFixture::Registration#")
                && !k.starts_with("Payments::Payment#")));
    }

    #[tokio::test]
    async fn registrations_route_runs_the_whole_dispatch_chain_and_returns_a_real_mock_checkout_url(
    ) {
        let client = scratch_db("hecks_host_web_test_registrations_happy_path").await;
        provision_lineage(
            &*client.lock().await,
            "CheckoutFixture",
            1,
            &["Event", "Registration", "Payment"],
        )
        .await;
        let config = checkout_config(1);
        let wasm_path = checkout_wasm_path();

        schedule_event(&client, &wasm_path, &config, "happy-event", 4200).await;

        // No connection: checkout is genuinely on the mock walkthrough, not
        // a misconfiguration — the whole chain runs and returns a real
        // checkout URL, never a 500.
        let body = json!({"event_slug": "happy-event", "name": "Ada Lovelace", "email": "ada@example.com"}).to_string();
        let response = registrations_route(
            &body,
            &payments::test_platform(),
            Host::new(&client, &wasm_path, &config, &lambda_client::NeverInvoker),
            &crate::commerce_ir::fixture_payments(),
        )
        .await;
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
        let registration = instances
            .iter()
            .find(|(k, _)| k.starts_with("CheckoutFixture::Registration#"))
            .map(|(_, v)| v);
        let payment = instances
            .iter()
            .find(|(k, _)| k.starts_with("Payments::Payment#"))
            .map(|(_, v)| v);
        assert!(
            registration.is_some(),
            "Registration.Request should have committed for real: {instances:?}"
        );
        assert!(
            payment.is_some(),
            "Payment.Initiate should have committed for real: {instances:?}"
        );

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
        provision_lineage(
            &*client.lock().await,
            "CheckoutFixture",
            1,
            &["Event", "Registration", "Payment"],
        )
        .await;
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
        let response = registrations_route(
            &body,
            &payments::test_platform(),
            Host::new(&client, &wasm_path, &config, &lambda_client::NeverInvoker),
            &crate::commerce_ir::fixture_payments(),
        )
        .await;
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
        provision_lineage(
            &*client.lock().await,
            "CheckoutFixture",
            1,
            &["Event", "Registration", "Payment"],
        )
        .await;
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
            let response = registrations_route(
                &body,
                &payments::test_platform(),
                Host::new(&client, &wasm_path, &config, &lambda_client::NeverInvoker),
                &crate::commerce_ir::fixture_payments(),
            )
            .await;
            assert_eq!(response["statusCode"], 200, "{response:?}");
            let body: Value = serde_json::from_str(response["body"].as_str().unwrap()).unwrap();
            // checkout_url is the /pay/<id>.html walkthrough page; return_to
            // is double-encoded (once for /pay's success_url, once more inside
            // it) so it shows up as "%252F".
            let checkout_url = body["checkout_url"].as_str().unwrap();
            let parsed = reqwest::Url::parse(checkout_url).unwrap();
            let success_url = parsed
                .query_pairs()
                .find(|(k, _)| k == "success_url")
                .map(|(_, v)| v.into_owned())
                .unwrap_or_default();
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
        provision_lineage(
            &*client.lock().await,
            "CheckoutFixture",
            1,
            &["Event", "Registration", "Payment"],
        )
        .await;
        let config = checkout_config(1);
        let wasm_path = checkout_wasm_path();

        schedule_event(&client, &wasm_path, &config, "mock-loop-event", 4200).await;

        let body = json!({"event_slug": "mock-loop-event", "name": "Ada Lovelace", "email": "ada@example.com"}).to_string();
        let response = registrations_route(
            &body,
            &payments::test_platform(),
            Host::new(&client, &wasm_path, &config, &lambda_client::NeverInvoker),
            &crate::commerce_ir::fixture_payments(),
        )
        .await;
        assert_eq!(response["statusCode"], 200, "{response:?}");
        let response_body: Value =
            serde_json::from_str(response["body"].as_str().unwrap()).unwrap();
        let reference = response_body["registration_id"]
            .as_str()
            .unwrap()
            .to_string();

        let secret = MOCK_STRIPE_WEBHOOK_SECRET;
        let payload = json!({
            "type": "checkout.session.completed",
            "data": {"object": {"id": format!("cs_manual_{reference}"), "metadata": {"registration_id": reference}}},
        }).to_string();
        let now = now_secs();
        let header = sign_stripe_header(secret, now, &payload);

        let response = webhook_route(
            &payload,
            &header,
            &payments::test_platform(),
            Host::new(&client, &wasm_path, &config, &lambda_client::NeverInvoker),
            &crate::commerce_ir::fixture_payments(),
        )
        .await;
        assert_eq!(response["statusCode"], 200, "{response:?}");

        let read = dispatch::read(&client, &wasm_path).await.unwrap();
        let payment = &read["instances"][format!("Payments::Payment#{reference}")];
        assert_eq!(payment["status"], "succeeded");
        assert_eq!(
            payment["transaction_id"]["value"],
            format!("cs_manual_{reference}")
        );
    }

    #[tokio::test]
    async fn webhook_route_rejects_a_bad_signature_before_touching_the_domain_at_all() {
        let client = scratch_db("hecks_host_web_test_webhook_bad_sig").await;
        provision_lineage(
            &*client.lock().await,
            "CheckoutFixture",
            1,
            &["Event", "Registration", "Payment"],
        )
        .await;

        let payload =
            json!({"type": "checkout.session.completed", "data": {"object": {}}}).to_string();
        let bad_header = "t=1700000000,v1=deadbeef";

        let response = webhook_route(
            &payload,
            bad_header,
            &payments::test_platform_with_secret("whsec_test_bad_sig"),
            Host::new(
                &client,
                &checkout_wasm_path(),
                &checkout_config(1),
                &lambda_client::NeverInvoker,
            ),
            &crate::commerce_ir::fixture_payments(),
        )
        .await;
        assert_eq!(response["statusCode"], 400);
    }

    #[tokio::test]
    async fn webhook_route_settles_a_payment_on_checkout_session_completed() {
        let client = scratch_db("hecks_host_web_test_webhook_completed").await;
        provision_lineage(
            &*client.lock().await,
            "CheckoutFixture",
            1,
            &["Event", "Registration", "Payment"],
        )
        .await;
        let config = checkout_config(1);
        let wasm_path = checkout_wasm_path();

        schedule_event(&client, &wasm_path, &config, "webhook-event", 4200).await;
        let initiate = dispatch::handle(
            Host::new(&client, &wasm_path, &config, &lambda_client::NeverInvoker),
            "Payments::Payment.Initiate",
            json!({
                "reference": {"value": "REG-WEBHOOK-1"}, "processor": {"value": "stripe"},
                "payment_type": {"value": "card"}, "amount": {"cents": 4200},
                "client": {"name": "Ada Lovelace", "email": "ada@example.com"},
            }),
            None,
        )
        .await
        .unwrap();
        assert!(initiate.accepted, "{:?}", initiate.result);

        let secret = "whsec_test_completed";
        let payload = json!({
            "type": "checkout.session.completed",
            "data": {"object": {
                "metadata": {"registration_id": "REG-WEBHOOK-1"}, "payment_intent": "pi_test_abc",
                "payment_status": "paid", "amount_total": 4200, "currency": "usd",
            }},
        })
        .to_string();
        let now = now_secs();
        let header = sign_stripe_header(secret, now, &payload);

        let response = webhook_route(
            &payload,
            &header,
            &payments::test_platform_with_secret(secret),
            Host::new(&client, &wasm_path, &config, &lambda_client::NeverInvoker),
            &crate::commerce_ir::fixture_payments(),
        )
        .await;
        assert_eq!(response["statusCode"], 200, "{response:?}");

        let read = dispatch::read(&client, &wasm_path).await.unwrap();
        let payment = &read["instances"]["Payments::Payment#REG-WEBHOOK-1"];
        assert_eq!(payment["status"], "succeeded");
        assert_eq!(payment["transaction_id"]["value"], "pi_test_abc");

        // A redelivered webhook (Stripe's delivery is at-least-once) for an
        // already-succeeded payment must still answer 200 — the refusal
        // underneath is a benign no-op, not surfaced as an error.
        let redelivered = webhook_route(
            &payload,
            &header,
            &payments::test_platform_with_secret(secret),
            Host::new(&client, &wasm_path, &config, &lambda_client::NeverInvoker),
            &crate::commerce_ir::fixture_payments(),
        )
        .await;
        assert_eq!(redelivered["statusCode"], 200, "a redelivered webhook must not surface the resulting refusal as an error: {redelivered:?}");
    }

    // A scratch fixture with a scheduled event and a pending 4200-cent Stripe Payment `reference`.
    async fn stripe_payment_db(name: &str, reference: &str) -> Mutex<Client> {
        let client = scratch_db(name).await;
        provision_lineage(
            &*client.lock().await,
            "CheckoutFixture",
            1,
            &["Event", "Registration", "Payment"],
        )
        .await;
        let (config, wasm_path) = (checkout_config(1), checkout_wasm_path());
        schedule_event(&client, &wasm_path, &config, "webhook-event", 4200).await;
        let initiate = dispatch::handle(
            Host::new(&client, &wasm_path, &config, &lambda_client::NeverInvoker),
            "Payments::Payment.Initiate",
            json!({
                "reference": {"value": reference}, "processor": {"value": "stripe"},
                "payment_type": {"value": "card"}, "amount": {"cents": 4200},
                "client": {"name": "Ada Lovelace", "email": "ada@example.com"},
            }),
            None,
        )
        .await
        .unwrap();
        assert!(initiate.accepted, "{:?}", initiate.result);
        client
    }

    // Delivers one signed Checkout Session event for `reference` and answers the Payment's status.
    async fn deliver_session_event(
        client: &Mutex<Client>,
        reference: &str,
        event_type: &str,
        session: Value,
    ) -> Value {
        let secret = "whsec_test_session";
        let mut object = session;
        object["metadata"] = json!({"registration_id": reference});
        let payload = json!({"type": event_type, "data": {"object": object}}).to_string();
        let header = sign_stripe_header(secret, now_secs(), &payload);
        let (config, wasm_path) = (checkout_config(1), checkout_wasm_path());
        let response = webhook_route(
            &payload,
            &header,
            &payments::test_platform_with_secret(secret),
            Host::new(client, &wasm_path, &config, &lambda_client::NeverInvoker),
            &crate::commerce_ir::fixture_payments(),
        )
        .await;
        assert_eq!(response["statusCode"], 200, "{response:?}");
        let read = dispatch::read(client, &wasm_path).await.unwrap();
        read["instances"][format!("Payments::Payment#{reference}")]["status"].clone()
    }

    // A completed session settles the Payment only when Stripe says it is paid, for the
    // Payment's amount, in its currency; a delayed method settles on its own later event.
    #[tokio::test]
    async fn webhook_route_settles_only_a_session_paid_in_full() {
        let reference = "REG-WEBHOOK-PAID";
        let client = stripe_payment_db("hecks_host_web_test_webhook_paid_in_full", reference).await;
        let completed = "checkout.session.completed";
        for (session, why) in [
            (
                json!({"payment_status": "unpaid", "amount_total": 4200, "currency": "usd"}),
                "a delayed method, not yet paid",
            ),
            (
                json!({"payment_status": "paid", "amount_total": 100, "currency": "usd"}),
                "another amount",
            ),
            (
                json!({"payment_status": "paid", "amount_total": 4200, "currency": "eur"}),
                "another currency",
            ),
            (json!({"id": "cs_bare"}), "no payment facts at all"),
        ] {
            let status = deliver_session_event(&client, reference, completed, session).await;
            assert_eq!(status, "pending", "{why} must not settle the payment");
        }

        let paid = json!({"payment_status": "paid", "amount_total": 4200, "currency": "usd"});
        let status = deliver_session_event(
            &client,
            reference,
            "checkout.session.async_payment_succeeded",
            paid,
        )
        .await;
        assert_eq!(status, "succeeded", "the delayed payment settled");
    }

    #[tokio::test]
    async fn webhook_route_fails_a_payment_whose_delayed_payment_failed() {
        let reference = "REG-WEBHOOK-ASYNC-FAIL";
        let client = stripe_payment_db("hecks_host_web_test_webhook_async_failed", reference).await;
        let unpaid = json!({"payment_status": "unpaid", "amount_total": 4200, "currency": "usd"});
        let failed = "checkout.session.async_payment_failed";
        assert_eq!(
            deliver_session_event(&client, reference, failed, unpaid).await,
            "failed"
        );
    }

    #[tokio::test]
    async fn webhook_route_declines_a_payment_on_checkout_session_expired() {
        let client = scratch_db("hecks_host_web_test_webhook_expired").await;
        provision_lineage(
            &*client.lock().await,
            "CheckoutFixture",
            1,
            &["Event", "Registration", "Payment"],
        )
        .await;
        let config = checkout_config(1);
        let wasm_path = checkout_wasm_path();

        schedule_event(&client, &wasm_path, &config, "webhook-event-2", 4200).await;
        dispatch::handle(
            Host::new(&client, &wasm_path, &config, &lambda_client::NeverInvoker),
            "Payments::Payment.Initiate",
            json!({
                "reference": {"value": "REG-WEBHOOK-2"}, "processor": {"value": "stripe"},
                "payment_type": {"value": "card"}, "amount": {"cents": 4200},
                "client": {"name": "Ada Lovelace", "email": "ada@example.com"},
            }),
            None,
        )
        .await
        .unwrap()
        .accepted
        .then_some(())
        .expect("initiate should succeed");

        let secret = "whsec_test_expired";
        let payload = json!({
            "type": "checkout.session.expired",
            "data": {"object": {"metadata": {"registration_id": "REG-WEBHOOK-2"}}},
        })
        .to_string();
        let now = now_secs();
        let header = sign_stripe_header(secret, now, &payload);

        let response = webhook_route(
            &payload,
            &header,
            &payments::test_platform_with_secret(secret),
            Host::new(&client, &wasm_path, &config, &lambda_client::NeverInvoker),
            &crate::commerce_ir::fixture_payments(),
        )
        .await;
        assert_eq!(response["statusCode"], 200, "{response:?}");

        let read = dispatch::read(&client, &wasm_path).await.unwrap();
        let payment = &read["instances"]["Payments::Payment#REG-WEBHOOK-2"];
        assert_eq!(payment["status"], "failed");
        assert_eq!(payment["failure_reason"]["value"], "checkout_expired");
    }

    #[tokio::test]
    async fn webhook_route_ignores_an_event_type_it_does_not_handle_and_still_answers_200() {
        let client = scratch_db("hecks_host_web_test_webhook_unhandled_type").await;
        provision_lineage(
            &*client.lock().await,
            "CheckoutFixture",
            1,
            &["Event", "Registration", "Payment"],
        )
        .await;

        let secret = "whsec_test_unhandled";
        let payload = json!({"type": "charge.refunded", "data": {"object": {"metadata": {"registration_id": "whatever"}}}}).to_string();
        let now = now_secs();
        let header = sign_stripe_header(secret, now, &payload);

        let response = webhook_route(
            &payload,
            &header,
            &payments::test_platform_with_secret(secret),
            Host::new(
                &client,
                &checkout_wasm_path(),
                &checkout_config(1),
                &lambda_client::NeverInvoker,
            ),
            &crate::commerce_ir::fixture_payments(),
        )
        .await;
        assert_eq!(response["statusCode"], 200);
    }
}
