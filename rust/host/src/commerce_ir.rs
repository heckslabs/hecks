// The commerce capability bindings (newsletter, payments, registrations, payment connection), read
// from `ir.json`'s own keys. Split out of `ir.rs` so the commerce modules that use them move as one.

use crate::ir::ir;
use serde_json::Value;

/// The chapter that answers the guest newsletter signup, read from
/// `ir.json`'s own `newsletter` key. `None` when nothing provides it.
#[derive(Debug, Clone, PartialEq)]
pub struct NewsletterProvider {
    /// Chapter name, e.g. `Newsletter`.
    pub provider: String,
    /// Qualified subscribe command, e.g. `Newsletter::Subscriber.Subscribe`.
    pub subscribe: String,
    /// Qualified add-name command, e.g. `Newsletter::Subscriber.AddName`.
    pub add_name: String,
    /// Qualified confirm command, e.g. `Newsletter::Subscriber.Confirm`.
    pub confirm: String,
    /// Qualified unsubscribe command, e.g. `Newsletter::Subscriber.Unsubscribe`.
    pub unsubscribe: String,
    /// Qualified subscribing aggregate, e.g. `Newsletter::Subscriber`.
    pub aggregate: String,
    /// Subscriber states awaiting the emailed confirm link: the
    /// `awaiting_confirmation` list of the `newsletter` fact (the lifecycle's
    /// mark), or [`LEGACY_AWAITING_CONFIRMATION`] when the chapter declares none.
    pub awaiting_confirmation: Vec<String>,
    /// Subscriber states that receive each issue: the `receives_issues` list,
    /// or [`LEGACY_RECEIVES_ISSUES`] when the chapter declares none.
    pub receives_issues: Vec<String>,
    /// Subscriber states of someone who has left: the `left` list, or
    /// [`LEGACY_LEFT`] when the chapter declares none.
    pub left: Vec<String>,
    /// Seconds the emailed confirm link stays valid: the `confirm_window` of
    /// the `newsletter` fact (ADR 0098), or [`LEGACY_CONFIRM_WINDOW_SECS`].
    pub confirm_window: u64,
    /// Seconds an emailed unsubscribe link stays valid: the `unsubscribe_window`,
    /// or [`LEGACY_UNSUBSCRIBE_WINDOW_SECS`].
    pub unsubscribe_window: u64,
}

/// LEGACY DEFAULT: how long the emailed confirm link lasts (14 days), used
/// while the `newsletter` fact carries no `confirm_window`, because the
/// Newsletter chapter predates ADR 0098 and does not declare
/// `provides "newsletter", ..., confirm_window: "Subscriber.confirm_window"`.
/// Delete this (and the fallback in `newsletter_provider`) once every shipped
/// Newsletter bluebook does.
pub const LEGACY_CONFIRM_WINDOW_SECS: u64 = 14 * 24 * 60 * 60;

/// LEGACY DEFAULT: how long an emailed unsubscribe link lasts (730 days), used
/// while the `newsletter` fact carries no `unsubscribe_window` (see
/// [`LEGACY_CONFIRM_WINDOW_SECS`]).
pub const LEGACY_UNSUBSCRIBE_WINDOW_SECS: u64 = 730 * 24 * 60 * 60;

/// The whole seconds the fact `fact` lists under `key`: an attribute default
/// resolved by the exporter (ADR 0098). `None` when the fact omits it.
fn declared_seconds(fact: &Value, key: &str) -> Option<u64> {
    fact.get(key)?.as_u64().filter(|seconds| *seconds > 0)
}

/// The declared seconds for `key`, else `legacy` with a single warning per process.
fn seconds_or_legacy(fact: &Value, capability: &str, key: &str, legacy: u64, warned: &std::sync::Once) -> u64 {
    declared_seconds(fact, key).unwrap_or_else(|| {
        warned.call_once(|| eprintln!("{capability} capability declares no {key}; using built-in default"));
        legacy
    })
}

/// The checkout boundary's windows, read from `ir.json`'s own `checkout` key
/// (ADR 0098). Always present: a window the chapter does not declare takes its
/// labelled legacy default.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct CheckoutWindows {
    /// Seconds either side of now a signed webhook's timestamp may sit.
    pub webhook_tolerance: i64,
    /// Seconds a checkout session holds its seat (before the processor's own
    /// minimum is applied by the checkout adapter).
    pub session_hold: i64,
}

/// LEGACY DEFAULT: the webhook freshness window (5 minutes), used while the
/// `checkout` fact carries no `webhook_tolerance`, because no shipped Checkout
/// bluebook declares `provides "checkout", webhook_tolerance: "WebhookReceipt.tolerance"`.
/// Delete this (and the fallback in `checkout_windows`) once every one does.
pub const LEGACY_WEBHOOK_TOLERANCE_SECS: i64 = 300;

/// LEGACY DEFAULT: the seat hold of a session (30 minutes), used while the
/// `checkout` fact carries no `session_hold` (see [`LEGACY_WEBHOOK_TOLERANCE_SECS`]).
pub const LEGACY_SESSION_HOLD_SECS: i64 = 30 * 60;

/// The checkout windows `domain_ir` declares, each falling back to its legacy default.
pub fn checkout_windows(domain_ir: &Value) -> CheckoutWindows {
    static TOLERANCE_WARNED: std::sync::Once = std::sync::Once::new();
    static HOLD_WARNED: std::sync::Once = std::sync::Once::new();
    let fact = domain_ir.get("checkout").unwrap_or(&Value::Null);
    let seconds = |key, legacy: i64, warned| seconds_or_legacy(fact, "checkout", key, legacy as u64, warned) as i64;
    CheckoutWindows {
        webhook_tolerance: seconds("webhook_tolerance", LEGACY_WEBHOOK_TOLERANCE_SECS, &TOLERANCE_WARNED),
        session_hold: seconds("session_hold", LEGACY_SESSION_HOLD_SECS, &HOLD_WARNED),
    }
}

/// The checkout windows of the IR this host loaded (legacy defaults without one).
pub fn checkout_windows_binding() -> CheckoutWindows {
    checkout_windows(ir().unwrap_or(&Value::Null))
}

/// The confirm-link and unsubscribe-link windows of the IR this host loaded:
/// `(confirm, unsubscribe)` seconds, legacy defaults without a `newsletter` fact.
pub fn newsletter_windows_binding() -> (u64, u64) {
    ir().and_then(newsletter_provider)
        .map(|p| (p.confirm_window, p.unsubscribe_window))
        .unwrap_or((LEGACY_CONFIRM_WINDOW_SECS, LEGACY_UNSUBSCRIBE_WINDOW_SECS))
}

/// LEGACY DEFAULT: the states a new subscriber waits in, used while the
/// `newsletter` fact carries no `awaiting_confirmation` list, because the
/// Newsletter chapter predates the marks and does not declare
/// `provides "newsletter", ..., awaiting_confirmation: "Subscriber.awaiting_confirmation"`.
/// Delete this (and the fallback in `newsletter_provider`) once every shipped
/// Newsletter bluebook does.
pub const LEGACY_AWAITING_CONFIRMATION: [&str; 1] = ["pending"];

/// LEGACY DEFAULT: the states that receive an issue, used while the
/// `newsletter` fact carries no `receives_issues` list (see
/// [`LEGACY_AWAITING_CONFIRMATION`]).
pub const LEGACY_RECEIVES_ISSUES: [&str; 1] = ["confirmed"];

/// LEGACY DEFAULT: the states of a subscriber who has left, used while the
/// `newsletter` fact carries no `left` list (see [`LEGACY_AWAITING_CONFIRMATION`]).
pub const LEGACY_LEFT: [&str; 1] = ["unsubscribed"];

/// The states the `newsletter` fact lists under `key`: a lifecycle mark
/// resolved by the exporter. `None` when the fact omits it.
fn declared_states(fact: &Value, key: &str) -> Option<Vec<String>> {
    let states = fact.get(key)?.as_array()?;
    Some(states.iter().filter_map(|s| s.as_str().map(String::from)).collect())
}

/// The declared states for `key`, else `legacy` with a single warning per process.
fn states_or_legacy(fact: &Value, key: &str, legacy: &[&str], warned: &std::sync::Once) -> Vec<String> {
    declared_states(fact, key).unwrap_or_else(|| {
        warned.call_once(|| eprintln!("newsletter capability declares no {key}; using built-in default"));
        legacy.iter().map(|s| s.to_string()).collect()
    })
}

impl NewsletterProvider {
    /// Whether `status` is a state awaiting confirmation.
    pub fn is_awaiting_confirmation(&self, status: Option<&str>) -> bool {
        status.is_some_and(|s| self.awaiting_confirmation.iter().any(|m| m == s))
    }

    /// Whether `status` is a state that receives issues.
    pub fn receives_issues(&self, status: Option<&str>) -> bool {
        status.is_some_and(|s| self.receives_issues.iter().any(|m| m == s))
    }

    /// Whether `status` is a state of a subscriber who has left.
    pub fn has_left(&self, status: Option<&str>) -> bool {
        status.is_some_and(|s| self.left.iter().any(|m| m == s))
    }

    /// The state a subscriber is reported in when none is recorded yet: the
    /// first awaiting-confirmation state.
    pub fn initial_status(&self) -> &str {
        self.awaiting_confirmation.first().map(String::as_str).unwrap_or("")
    }

    /// The prefix every subscriber's key in a `dispatch::read` `instances`
    /// map starts with, e.g. `Newsletter::Subscriber#`.
    pub fn instance_prefix(&self) -> String {
        format!("{}#", self.aggregate)
    }
}

/// Whether the domain's own `aggregate`'s `command` declares an argument
/// named `field` — so a route only sends an argument the command declares.
pub fn command_declares(domain_ir: &Value, aggregate: &str, command: &str, field: &str) -> bool {
    let named = |value: &Value, name: &str| value.get("name").and_then(|n| n.as_str()) == Some(name);
    let Some(aggregates) = domain_ir.get("aggregates").and_then(|a| a.as_array()) else {
        return false;
    };
    aggregates
        .iter()
        .filter(|a| named(a, aggregate))
        .filter_map(|a| a.get("commands").and_then(|c| c.as_array()))
        .flatten()
        .filter(|c| named(c, command))
        .filter_map(|c| c.get("attributes").and_then(|a| a.as_array()))
        .flatten()
        .any(|attribute| named(attribute, field))
}

pub fn newsletter_provider(domain_ir: &Value) -> Option<NewsletterProvider> {
    static AWAITING_WARNED: std::sync::Once = std::sync::Once::new();
    static RECEIVES_WARNED: std::sync::Once = std::sync::Once::new();
    static LEFT_WARNED: std::sync::Once = std::sync::Once::new();
    static CONFIRM_WINDOW_WARNED: std::sync::Once = std::sync::Once::new();
    static UNSUBSCRIBE_WINDOW_WARNED: std::sync::Once = std::sync::Once::new();
    let fact = domain_ir.get("newsletter")?;
    Some(NewsletterProvider {
        confirm_window: seconds_or_legacy(fact, "newsletter", "confirm_window", LEGACY_CONFIRM_WINDOW_SECS, &CONFIRM_WINDOW_WARNED),
        unsubscribe_window: seconds_or_legacy(fact, "newsletter", "unsubscribe_window", LEGACY_UNSUBSCRIBE_WINDOW_SECS, &UNSUBSCRIBE_WINDOW_WARNED),
        awaiting_confirmation: states_or_legacy(fact, "awaiting_confirmation", &LEGACY_AWAITING_CONFIRMATION, &AWAITING_WARNED),
        receives_issues: states_or_legacy(fact, "receives_issues", &LEGACY_RECEIVES_ISSUES, &RECEIVES_WARNED),
        left: states_or_legacy(fact, "left", &LEGACY_LEFT, &LEFT_WARNED),
        provider: fact.get("provider")?.as_str()?.to_string(),
        subscribe: fact.get("subscribe")?.as_str()?.to_string(),
        add_name: fact.get("add_name")?.as_str()?.to_string(),
        confirm: fact.get("confirm")?.as_str()?.to_string(),
        unsubscribe: fact.get("unsubscribe")?.as_str()?.to_string(),
        aggregate: fact.get("aggregate")?.as_str()?.to_string(),
    })
}

/// The chapter that declares `provides "newsletter_issues"`, read from
/// `ir.json`'s own `newsletter_issues` key. Omitted when nothing declares it.
#[derive(Debug, Clone, PartialEq)]
pub struct NewsletterIssuesProvider {
    /// Qualified send command, e.g. `Newsletter::Issue.Send`.
    pub send_issue: String,
    /// Qualified delivery-record command, e.g. `Newsletter::Delivery.Record`.
    pub record_delivery: String,
    /// Qualified issue aggregate, e.g. `Newsletter::Issue`.
    pub issue_aggregate: String,
}

impl NewsletterIssuesProvider {
    /// The prefix every issue's key in a `dispatch::read` `instances` map
    /// starts with, e.g. `Newsletter::Issue#`.
    pub fn issue_prefix(&self) -> String {
        format!("{}#", self.issue_aggregate)
    }
}

/// The declared issue-sending verbs, or `None` when the IR has no
/// `newsletter_issues` key.
pub fn newsletter_issues_provider(domain_ir: &Value) -> Option<NewsletterIssuesProvider> {
    let fact = domain_ir.get("newsletter_issues")?;
    Some(NewsletterIssuesProvider {
        send_issue: fact.get("send_issue")?.as_str()?.to_string(),
        record_delivery: fact.get("record_delivery")?.as_str()?.to_string(),
        issue_aggregate: fact.get("issue_aggregate")?.as_str()?.to_string(),
    })
}


/// The chapter that takes payments, read from `ir.json`'s own `payments`
/// key. `None` when nothing provides it.
#[derive(Debug, Clone, PartialEq)]
pub struct PaymentsProvider {
    /// Chapter name, e.g. `Payments`.
    pub provider: String,
    /// Qualified initiate command, e.g. `Payments::Payment.Initiate`.
    pub initiate: String,
    /// Qualified port operation the processor's success report dispatches,
    /// e.g. `Payments::Payment.PaymentGateway.Succeeded`.
    pub succeeded: String,
    /// Qualified port operation the processor's failure report dispatches,
    /// e.g. `Payments::Payment.PaymentGateway.Failed`.
    pub failed: String,
    /// Qualified paying aggregate, e.g. `Payments::Payment`.
    pub aggregate: String,
    /// Payment states whose registration still holds a seat: the `holds_seat`
    /// list of the `payments` fact (the payment lifecycle's mark), or
    /// [`LEGACY_HOLDS_SEAT`] when the chapter declares none.
    pub holds_seat: Vec<String>,
    /// The failure reason a lapsed checkout hold records: the `lapse_reason` of
    /// the `payments` fact (ADR 0099), or [`LEGACY_LAPSE_REASON`] when the
    /// chapter declares none.
    pub lapse_reason: String,
}

/// LEGACY DEFAULT: the failure reason a lapsed hold records, used while the
/// `payments` capability fact carries no `lapse_reason` because the Payments
/// chapter predates `provides "payments", lapse_reason: "Payment.lapse_reason"`.
/// Delete this (and the fallback in `payments_provider`) once every shipped
/// Payments bluebook declares it.
pub const LEGACY_LAPSE_REASON: &str = "checkout_expired";

/// LEGACY DEFAULT: the registration attributes guessed to hold the timestamp, in
/// order, used while the `registrations` fact carries no `registered_at` because
/// the chapter predates `provides "registrations", registered_at: "Registration.requested_at"`.
/// Delete this (and the fallback in `registrations_provider`) once every shipped
/// bluebook declares it.
pub const LEGACY_REGISTERED_AT: [&str; 4] = ["created_at", "registered_at", "requested_at", "occurred_at"];

/// LEGACY DEFAULT: the seat-holding payment states used while the `payments`
/// capability fact carries no `holds_seat` list, because the Payments chapter
/// predates `mark :holds_seat` and does not declare
/// `provides "payments", holds_seat: "Payment.holds_seat"`. Delete this (and the
/// fallback in `payments_provider`) once every shipped Payments bluebook does.
pub const LEGACY_HOLDS_SEAT: [&str; 4] = ["pending", "succeeded", "refunding", "disputed"];

/// The states the `payments` fact lists under `holds_seat`: the aggregate's
/// lifecycle mark, resolved by the exporter. `None` when the fact omits it.
fn declared_holds_seat(fact: &Value) -> Option<Vec<String>> {
    let states = fact.get("holds_seat")?.as_array()?;
    Some(states.iter().filter_map(|s| s.as_str().map(String::from)).collect())
}

impl PaymentsProvider {
    /// The prefix every payment's key in a `dispatch::read` `instances` map
    /// starts with, e.g. `Payments::Payment#`.
    pub fn instance_prefix(&self) -> String {
        format!("{}#", self.aggregate)
    }
}

pub fn payments_provider(domain_ir: &Value) -> Option<PaymentsProvider> {
    let fact = domain_ir.get("payments")?;
    let aggregate = fact.get("aggregate")?.as_str()?.to_string();
    let holds_seat = declared_holds_seat(fact).unwrap_or_else(|| {
        static WARNED: std::sync::Once = std::sync::Once::new();
        WARNED.call_once(|| eprintln!("payments capability declares no holds_seat; using built-in default"));
        LEGACY_HOLDS_SEAT.iter().map(|s| s.to_string()).collect()
    });
    Some(PaymentsProvider {
        provider: fact.get("provider")?.as_str()?.to_string(),
        initiate: fact.get("initiate")?.as_str()?.to_string(),
        succeeded: fact.get("succeeded")?.as_str()?.to_string(),
        failed: fact.get("failed")?.as_str()?.to_string(),
        aggregate,
        holds_seat,
        lapse_reason: fact.get("lapse_reason").and_then(|v| v.as_str()).filter(|v| !v.is_empty()).map(String::from).unwrap_or_else(|| {
            static WARNED: std::sync::Once = std::sync::Once::new();
            WARNED.call_once(|| eprintln!("payments capability declares no lapse_reason; using built-in default"));
            LEGACY_LAPSE_REASON.to_string()
        }),
    })
}

/// The chapter that answers scheduling sessions and taking registrations,
/// read from `ir.json`'s own `registrations` key. `None` when nothing provides it.
#[derive(Debug, Clone, PartialEq)]
pub struct RegistrationsProvider {
    /// Chapter name, e.g. `Studio`.
    pub provider: String,
    /// Qualified schedule command, e.g. `Studio::Event.Schedule`.
    pub schedule: String,
    /// Qualified request command, e.g. `Studio::Registration.Request`.
    pub request: String,
    /// Qualified event aggregate, e.g. `Studio::Event`.
    pub event_aggregate: String,
    /// Qualified registration aggregate, e.g. `Studio::Registration`.
    pub registration_aggregate: String,
    /// The registration attributes that may hold when it was asked for, in the order
    /// to try them: the one `registered_at` of the `registrations` fact names
    /// (ADR 0099), or [`LEGACY_REGISTERED_AT`] when the chapter declares none.
    pub timestamp_keys: Vec<String>,
}

impl RegistrationsProvider {
    /// The conventional names for a domain that declares no
    /// `provides "registrations"` — `Event`/`Registration` under the domain itself.
    pub fn conventional(domain: &str) -> Self {
        Self {
            provider: domain.to_string(),
            schedule: format!("{domain}::Event.Schedule"),
            request: format!("{domain}::Registration.Request"),
            event_aggregate: format!("{domain}::Event"),
            registration_aggregate: format!("{domain}::Registration"),
            timestamp_keys: LEGACY_REGISTERED_AT.iter().map(|k| k.to_string()).collect(),
        }
    }

    /// The prefix every event's key in a `dispatch::read` `instances` map
    /// starts with, e.g. `Studio::Event#`.
    pub fn event_prefix(&self) -> String {
        format!("{}#", self.event_aggregate)
    }

    /// The prefix every registration's key starts with, e.g.
    /// `Studio::Registration#`.
    pub fn registration_prefix(&self) -> String {
        format!("{}#", self.registration_aggregate)
    }

    /// The request command's own aggregate and command name without the
    /// chapter qualifier, e.g. `("Registration", "Request")`, as `command_declares` expects.
    pub fn request_target(&self) -> Option<(&str, &str)> {
        self.request.rsplit("::").next()?.split_once('.')
    }
}

pub fn registrations_provider(domain_ir: &Value) -> Option<RegistrationsProvider> {
    let fact = domain_ir.get("registrations")?;
    Some(RegistrationsProvider {
        provider: fact.get("provider")?.as_str()?.to_string(),
        schedule: fact.get("schedule")?.as_str()?.to_string(),
        request: fact.get("request")?.as_str()?.to_string(),
        event_aggregate: fact.get("event_aggregate")?.as_str()?.to_string(),
        registration_aggregate: fact.get("registration_aggregate")?.as_str()?.to_string(),
        timestamp_keys: match fact.get("registered_at").and_then(|v| v.as_str()).filter(|v| !v.is_empty()) {
            Some(declared) => vec![declared.to_string()],
            None => {
                static WARNED: std::sync::Once = std::sync::Once::new();
                WARNED.call_once(|| eprintln!("registrations capability declares no registered_at; using built-in default"));
                LEGACY_REGISTERED_AT.iter().map(|k| k.to_string()).collect()
            }
        },
    })
}

/// The registrations binding of the IR this host loaded, or the
/// conventional names for `domain` when the IR declares none.
pub fn registrations_binding(domain: &str) -> RegistrationsProvider {
    ir().and_then(registrations_provider).unwrap_or_else(|| RegistrationsProvider::conventional(domain))
}

/// One command of the payment-processor connection, by the role it plays —
/// resolved through `PaymentConnectionProvider::verb`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ConnectionVerb {
    Connect,
    Reconnect,
    Disconnect,
    Suspend,
    Resume,
    Enable,
    Disable,
}

/// The chapter that owns the business's payment-processor connection, read
/// from `ir.json`'s own `payment_connection` key. `None` when nothing provides it.
#[derive(Debug, Clone, PartialEq)]
pub struct PaymentConnectionProvider {
    /// Chapter name, e.g. `Studio`.
    pub provider: String,
    pub connect: String,
    pub reconnect: String,
    pub disconnect: String,
    pub suspend: String,
    pub resume: String,
    pub enable: String,
    pub disable: String,
    /// Qualified connection aggregate, e.g. `Studio::PaymentConnection`.
    pub aggregate: String,
}

impl PaymentConnectionProvider {
    /// The conventional names for a domain that declares no
    /// `provides "payment_connection"` — `PaymentConnection` under the domain itself.
    pub fn conventional(domain: &str) -> Self {
        let qualified = |command: &str| format!("{domain}::PaymentConnection.{command}");
        Self {
            provider: domain.to_string(),
            connect: qualified("Connect"),
            reconnect: qualified("Reconnect"),
            disconnect: qualified("Disconnect"),
            suspend: qualified("Suspend"),
            resume: qualified("Resume"),
            enable: qualified("EnablePayments"),
            disable: qualified("DisablePayments"),
            aggregate: format!("{domain}::PaymentConnection"),
        }
    }

    /// The prefix every connection's key in a `dispatch::read` `instances`
    /// map starts with, e.g. `Studio::PaymentConnection#`.
    pub fn instance_prefix(&self) -> String {
        format!("{}#", self.aggregate)
    }

    /// The qualified command that plays `which`.
    pub fn verb(&self, which: ConnectionVerb) -> &str {
        match which {
            ConnectionVerb::Connect => &self.connect,
            ConnectionVerb::Reconnect => &self.reconnect,
            ConnectionVerb::Disconnect => &self.disconnect,
            ConnectionVerb::Suspend => &self.suspend,
            ConnectionVerb::Resume => &self.resume,
            ConnectionVerb::Enable => &self.enable,
            ConnectionVerb::Disable => &self.disable,
        }
    }
}

pub fn payment_connection_provider(domain_ir: &Value) -> Option<PaymentConnectionProvider> {
    let fact = domain_ir.get("payment_connection")?;
    let text = |key: &str| Some(fact.get(key)?.as_str()?.to_string());
    Some(PaymentConnectionProvider {
        provider: text("provider")?,
        connect: text("connect")?,
        reconnect: text("reconnect")?,
        disconnect: text("disconnect")?,
        suspend: text("suspend")?,
        resume: text("resume")?,
        enable: text("enable")?,
        disable: text("disable")?,
        aggregate: text("aggregate")?,
    })
}

/// The payment-connection binding of the IR this host loaded, or the
/// conventional names for `domain` when the IR declares none.
pub fn payment_connection_binding(domain: &str) -> PaymentConnectionProvider {
    ir().and_then(payment_connection_provider).unwrap_or_else(|| PaymentConnectionProvider::conventional(domain))
}

/// The checkout fixture's own payments binding, read from its committed
/// `ir.json` — what the checkout routes' tests dispatch against.
#[cfg(test)]
pub fn fixture_ir() -> Value {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../src/generated/checkout_fixture/ir.json");
    serde_json::from_str(&std::fs::read_to_string(path).expect("checkout_fixture ir.json")).expect("valid json")
}

/// The checkout fixture's own payments binding.
#[cfg(test)]
pub fn fixture_payments() -> PaymentsProvider {
    payments_provider(&fixture_ir()).expect("the checkout fixture provides payments")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn newsletter_provider_reads_the_declared_capability() {
        let ir = serde_json::json!({
            "name": "Studio",
            "newsletter": {
                "provider": "Newsletter",
                "subscribe": "Newsletter::Subscriber.Subscribe",
                "add_name": "Newsletter::Subscriber.AddName",
                "confirm": "Newsletter::Subscriber.Confirm",
                "unsubscribe": "Newsletter::Subscriber.Unsubscribe",
                "aggregate": "Newsletter::Subscriber"
            }
        });
        let provider = newsletter_provider(&ir).expect("should find newsletter");
        assert_eq!(provider.provider, "Newsletter");
        assert_eq!(provider.subscribe, "Newsletter::Subscriber.Subscribe");
        assert_eq!(provider.add_name, "Newsletter::Subscriber.AddName");
        assert_eq!(provider.confirm, "Newsletter::Subscriber.Confirm");
        assert_eq!(provider.unsubscribe, "Newsletter::Subscriber.Unsubscribe");
        assert_eq!(provider.instance_prefix(), "Newsletter::Subscriber#");
        assert!(newsletter_provider(&serde_json::json!({ "name": "Pizzas" })).is_none());
    }

    fn newsletter_ir(marks: serde_json::Value) -> Value {
        let mut fact = serde_json::json!({
            "provider": "Newsletter",
            "subscribe": "Newsletter::Subscriber.Subscribe",
            "add_name": "Newsletter::Subscriber.AddName",
            "confirm": "Newsletter::Subscriber.Confirm",
            "unsubscribe": "Newsletter::Subscriber.Unsubscribe",
            "aggregate": "Newsletter::Subscriber"
        });
        for (key, states) in marks.as_object().into_iter().flatten() {
            fact[key] = states.clone();
        }
        serde_json::json!({ "name": "Studio", "newsletter": fact })
    }

    #[test]
    fn newsletter_provider_reads_the_marks_from_the_fact() {
        let ir = newsletter_ir(serde_json::json!({
            "awaiting_confirmation": ["invited"],
            "receives_issues": ["active", "vip"],
            "left": ["gone"]
        }));
        let provider = newsletter_provider(&ir).expect("newsletter");
        assert_eq!(provider.awaiting_confirmation, vec!["invited"]);
        assert_eq!(provider.receives_issues, vec!["active", "vip"]);
        assert_eq!(provider.left, vec!["gone"]);
        assert!(provider.is_awaiting_confirmation(Some("invited")));
        assert!(!provider.is_awaiting_confirmation(Some("pending")));
        assert!(provider.receives_issues(Some("vip")));
        assert!(!provider.receives_issues(Some("confirmed")));
        assert!(provider.has_left(Some("gone")));
        assert_eq!(provider.initial_status(), "invited");
    }

    #[test]
    fn newsletter_provider_falls_back_to_the_legacy_defaults_without_marks() {
        let provider = newsletter_provider(&newsletter_ir(serde_json::json!({}))).expect("newsletter");
        assert_eq!(provider.awaiting_confirmation, LEGACY_AWAITING_CONFIRMATION);
        assert_eq!(provider.receives_issues, LEGACY_RECEIVES_ISSUES);
        assert_eq!(provider.left, LEGACY_LEFT);
        assert!(provider.is_awaiting_confirmation(Some("pending")));
        assert!(provider.receives_issues(Some("confirmed")));
        assert!(provider.has_left(Some("unsubscribed")));
        assert!(!provider.has_left(None));
        assert_eq!(provider.initial_status(), "pending");
    }

    #[test]
    fn newsletter_provider_reads_the_link_windows_from_the_fact() {
        let ir = newsletter_ir(serde_json::json!({ "confirm_window": 3600, "unsubscribe_window": 7200 }));
        let provider = newsletter_provider(&ir).expect("newsletter");
        assert_eq!((provider.confirm_window, provider.unsubscribe_window), (3600, 7200));
    }

    #[test]
    fn newsletter_provider_falls_back_to_the_legacy_windows_without_them() {
        let provider = newsletter_provider(&newsletter_ir(serde_json::json!({}))).expect("newsletter");
        assert_eq!(provider.confirm_window, LEGACY_CONFIRM_WINDOW_SECS);
        assert_eq!(provider.unsubscribe_window, LEGACY_UNSUBSCRIBE_WINDOW_SECS);
        assert_eq!((LEGACY_CONFIRM_WINDOW_SECS, LEGACY_UNSUBSCRIBE_WINDOW_SECS), (1_209_600, 63_072_000));
    }

    #[test]
    fn checkout_windows_read_the_fact_and_fall_back_per_window() {
        let declared = serde_json::json!({ "checkout": { "provider": "Checkout", "webhook_tolerance": 120, "session_hold": 2400 } });
        assert_eq!(checkout_windows(&declared), CheckoutWindows { webhook_tolerance: 120, session_hold: 2400 });
        let partial = serde_json::json!({ "checkout": { "provider": "Checkout", "session_hold": 2400 } });
        assert_eq!(checkout_windows(&partial), CheckoutWindows { webhook_tolerance: LEGACY_WEBHOOK_TOLERANCE_SECS, session_hold: 2400 });
        let none = checkout_windows(&serde_json::json!({ "name": "Pizzas" }));
        assert_eq!(none, CheckoutWindows { webhook_tolerance: 300, session_hold: 1800 });
    }

    #[test]
    fn a_zero_or_non_numeric_window_is_not_a_declaration() {
        let ir = serde_json::json!({ "checkout": { "webhook_tolerance": 0, "session_hold": "soon" } });
        assert_eq!(checkout_windows(&ir), CheckoutWindows { webhook_tolerance: 300, session_hold: 1800 });
    }

    #[test]
    fn newsletter_issues_provider_reads_the_declared_capability() {
        let ir = serde_json::json!({
            "name": "Studio",
            "newsletter_issues": {
                "provider": "Newsletter",
                "send_issue": "Newsletter::Issue.Send",
                "record_delivery": "Newsletter::Delivery.Record",
                "issue_aggregate": "Newsletter::Issue",
                "delivery_aggregate": "Newsletter::Delivery"
            }
        });
        let provider = newsletter_issues_provider(&ir).expect("should find newsletter_issues");
        assert_eq!(provider.send_issue, "Newsletter::Issue.Send");
        assert_eq!(provider.record_delivery, "Newsletter::Delivery.Record");
        assert_eq!(provider.issue_prefix(), "Newsletter::Issue#");
        assert!(newsletter_issues_provider(&serde_json::json!({ "name": "Pizzas" })).is_none());
    }

    #[test]
    fn payments_provider_reads_the_declared_capability() {
        let ir = serde_json::json!({
            "name": "Studio",
            "payments": {
                "provider": "Payments",
                "initiate": "Payments::Payment.Initiate",
                "succeeded": "Payments::Payment.PaymentGateway.Succeeded",
                "failed": "Payments::Payment.PaymentGateway.Failed",
                "aggregate": "Payments::Payment"
            }
        });
        let provider = payments_provider(&ir).expect("should find payments");
        assert_eq!(provider.provider, "Payments");
        assert_eq!(provider.initiate, "Payments::Payment.Initiate");
        assert_eq!(provider.succeeded, "Payments::Payment.PaymentGateway.Succeeded");
        assert_eq!(provider.failed, "Payments::Payment.PaymentGateway.Failed");
        assert_eq!(provider.instance_prefix(), "Payments::Payment#");
        assert!(payments_provider(&serde_json::json!({ "name": "Pizzas" })).is_none());
    }

    fn payments_ir(holds_seat: Option<serde_json::Value>) -> Value {
        let mut fact = serde_json::json!({
            "provider": "Payments", "initiate": "Payments::Payment.Initiate",
            "succeeded": "Payments::Payment.PaymentGateway.Succeeded",
            "failed": "Payments::Payment.PaymentGateway.Failed", "aggregate": "Payments::Payment"
        });
        if let Some(states) = holds_seat {
            fact["holds_seat"] = states;
        }
        serde_json::json!({"name": "Studio", "payments": fact})
    }

    #[test]
    fn payments_provider_reads_holds_seat_from_the_fact() {
        let ir = payments_ir(Some(serde_json::json!(["pending", "paid"])));
        assert_eq!(declared_holds_seat(&ir["payments"]), Some(vec!["pending".to_string(), "paid".to_string()]));
        assert_eq!(payments_provider(&ir).expect("payments").holds_seat, vec!["pending", "paid"]);
    }

    #[test]
    fn the_checkout_fixture_ir_carries_holds_seat_with_no_fallback() {
        let ir = fixture_ir();
        assert_eq!(declared_holds_seat(&ir["payments"]), Some(vec!["pending".to_string(), "succeeded".to_string()]));
        assert_eq!(fixture_payments().holds_seat, vec!["pending", "succeeded"]);
    }

    #[test]
    fn payments_provider_falls_back_to_the_legacy_default_without_holds_seat() {
        assert_eq!(declared_holds_seat(&payments_ir(None)["payments"]), None);
        let held = payments_provider(&payments_ir(None)).expect("payments").holds_seat;
        assert_eq!(held, LEGACY_HOLDS_SEAT);
    }

    #[test]
    fn registrations_provider_reads_the_declared_capability() {
        let provider = registrations_provider(&fixture_ir()).expect("the checkout fixture provides registrations");
        assert_eq!(provider.schedule, "CheckoutFixture::Event.Schedule");
        assert_eq!(provider.request, "CheckoutFixture::Registration.Request");
        assert_eq!(provider.event_prefix(), "CheckoutFixture::Event#");
        assert_eq!(provider.registration_prefix(), "CheckoutFixture::Registration#");
        assert_eq!(provider.request_target(), Some(("Registration", "Request")));
    }

    #[test]
    fn the_conventional_registrations_names_match_what_the_fixture_declares() {
        let declared = registrations_provider(&fixture_ir()).expect("registrations");
        let conventional = RegistrationsProvider { timestamp_keys: declared.timestamp_keys.clone(), ..RegistrationsProvider::conventional("CheckoutFixture") };
        assert_eq!(declared, conventional);
    }

    #[test]
    fn the_registration_timestamp_is_the_declared_attribute_or_the_legacy_guess() {
        assert_eq!(registrations_provider(&fixture_ir()).expect("registrations").timestamp_keys, vec!["requested_at"]);
        let undeclared = serde_json::json!({"registrations": {
            "provider": "B", "schedule": "B::E.S", "request": "B::R.Q",
            "event_aggregate": "B::E", "registration_aggregate": "B::R"
        }});
        assert_eq!(registrations_provider(&undeclared).expect("registrations").timestamp_keys, LEGACY_REGISTERED_AT);
    }

    #[test]
    fn the_lapse_reason_is_the_declared_word_or_the_legacy_default() {
        assert_eq!(fixture_payments().lapse_reason, "checkout_expired");
        let mut ir = payments_ir(None);
        assert_eq!(payments_provider(&ir).expect("payments").lapse_reason, LEGACY_LAPSE_REASON);
        ir["payments"]["lapse_reason"] = serde_json::json!("hold_lapsed");
        assert_eq!(payments_provider(&ir).expect("payments").lapse_reason, "hold_lapsed");
    }

    #[test]
    fn a_declared_registrations_binding_names_whatever_the_chapter_calls_things() {
        let ir = serde_json::json!({"registrations": {
            "provider": "Bookings",
            "schedule": "Bookings::Session.Plan",
            "request": "Bookings::Seat.Claim",
            "event_aggregate": "Bookings::Session",
            "registration_aggregate": "Bookings::Seat"
        }});
        let provider = registrations_provider(&ir).expect("declared");
        assert_eq!(provider.event_prefix(), "Bookings::Session#");
        assert_eq!(provider.registration_prefix(), "Bookings::Seat#");
        assert_eq!(provider.request_target(), Some(("Seat", "Claim")));
    }

    #[test]
    fn registrations_provider_is_none_without_the_key() {
        assert_eq!(registrations_provider(&serde_json::json!({"name": "Pizzas"})), None);
    }

    #[test]
    fn registrations_binding_falls_back_to_the_conventional_names_when_no_ir_is_loaded() {
        assert_eq!(registrations_binding("Shop"), RegistrationsProvider::conventional("Shop"));
    }

    #[test]
    fn payment_connection_provider_reads_the_declared_capability() {
        let provider = payment_connection_provider(&fixture_ir()).expect("the checkout fixture provides payment_connection");
        assert_eq!(provider.verb(ConnectionVerb::Connect), "CheckoutFixture::PaymentConnection.Connect");
        assert_eq!(provider.verb(ConnectionVerb::Enable), "CheckoutFixture::PaymentConnection.EnablePayments");
        assert_eq!(provider.verb(ConnectionVerb::Disable), "CheckoutFixture::PaymentConnection.DisablePayments");
        assert_eq!(provider.instance_prefix(), "CheckoutFixture::PaymentConnection#");
    }

    #[test]
    fn the_conventional_payment_connection_names_match_what_the_fixture_declares() {
        assert_eq!(payment_connection_provider(&fixture_ir()), Some(PaymentConnectionProvider::conventional("CheckoutFixture")));
    }

    #[test]
    fn a_declared_payment_connection_binding_names_whatever_the_chapter_calls_things() {
        let ir = serde_json::json!({"payment_connection": {
            "provider": "Billing",
            "connect": "Billing::Link.Open", "reconnect": "Billing::Link.Reopen",
            "disconnect": "Billing::Link.Close", "suspend": "Billing::Link.Pause",
            "resume": "Billing::Link.Unpause", "enable": "Billing::Link.TurnOn",
            "disable": "Billing::Link.TurnOff", "aggregate": "Billing::Link"
        }});
        let provider = payment_connection_provider(&ir).expect("declared");
        assert_eq!(provider.verb(ConnectionVerb::Suspend), "Billing::Link.Pause");
        assert_eq!(provider.verb(ConnectionVerb::Resume), "Billing::Link.Unpause");
        assert_eq!(provider.instance_prefix(), "Billing::Link#");
    }

    #[test]
    fn payment_connection_binding_falls_back_to_the_conventional_names_when_no_ir_is_loaded() {
        assert_eq!(payment_connection_binding("Shop"), PaymentConnectionProvider::conventional("Shop"));
    }

    #[test]
    fn command_declares_finds_an_argument_on_the_named_command_only() {
        let ir = serde_json::json!({
            "aggregates": [
                {"name": "Registration", "commands": [
                    {"name": "Request", "attributes": [{"name": "email"}, {"name": "news_signup"}]},
                    {"name": "Cancel", "attributes": [{"name": "reason"}]}
                ]},
                {"name": "Event", "commands": [{"name": "Request", "attributes": [{"name": "slug"}]}]}
            ]
        });
        assert!(command_declares(&ir, "Registration", "Request", "news_signup"));
        assert!(!command_declares(&ir, "Registration", "Cancel", "news_signup"));
        assert!(!command_declares(&ir, "Event", "Request", "news_signup"));
        assert!(!command_declares(&ir, "Registration", "Request", "phone"));
        assert!(!command_declares(&serde_json::json!({"name": "Pizzas"}), "Registration", "Request", "news_signup"));
    }
}
