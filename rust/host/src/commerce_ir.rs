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
}

impl NewsletterProvider {
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
    let fact = domain_ir.get("newsletter")?;
    Some(NewsletterProvider {
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
    /// Payment states whose registration still holds a seat: the aggregate's
    /// lifecycle `holds_seat` mark, or [`LEGACY_HOLDS_SEAT`] when it declares none.
    pub holds_seat: Vec<String>,
}

/// LEGACY DEFAULT: the seat-holding payment states used while the payment
/// lifecycle declares no `holds_seat` mark. Delete this (and the fallback in
/// `payments_provider`) once the Payments bluebook declares
/// `mark :holds_seat, "pending", "succeeded", "refunding", "disputed"`.
pub const LEGACY_HOLDS_SEAT: [&str; 4] = ["pending", "succeeded", "refunding", "disputed"];

/// The states a lifecycle `mark` names on one aggregate, read from the IR's
/// `aggregates[].lifecycle.marks`. `qualified_aggregate` is `Chapter::Aggregate`;
/// it matches only when the chapter is this IR's own domain. `None` when the
/// aggregate, its lifecycle or the mark is absent.
pub fn lifecycle_mark(domain_ir: &Value, qualified_aggregate: &str, mark: &str) -> Option<Vec<String>> {
    let (chapter, name) = qualified_aggregate.rsplit_once("::")?;
    if domain_ir.get("name").and_then(|n| n.as_str()) != Some(chapter) {
        return None;
    }
    let aggregate = domain_ir.get("aggregates")?.as_array()?.iter().find(|a| a.get("name").and_then(|n| n.as_str()) == Some(name))?;
    let states = aggregate.get("lifecycle")?.get("marks")?.get(mark)?.as_array()?;
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
    let holds_seat = lifecycle_mark(domain_ir, &aggregate, "holds_seat").unwrap_or_else(|| {
        static WARNED: std::sync::Once = std::sync::Once::new();
        WARNED.call_once(|| eprintln!("payment lifecycle declares no holds_seat mark; using built-in default"));
        LEGACY_HOLDS_SEAT.iter().map(|s| s.to_string()).collect()
    });
    Some(PaymentsProvider {
        provider: fact.get("provider")?.as_str()?.to_string(),
        initiate: fact.get("initiate")?.as_str()?.to_string(),
        succeeded: fact.get("succeeded")?.as_str()?.to_string(),
        failed: fact.get("failed")?.as_str()?.to_string(),
        aggregate,
        holds_seat,
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

    fn payments_ir(marks: Option<serde_json::Value>) -> Value {
        let mut lifecycle = serde_json::json!({"field": "status", "default": "pending", "transitions": []});
        if let Some(marks) = marks {
            lifecycle["marks"] = marks;
        }
        serde_json::json!({
            "name": "Payments",
            "aggregates": [{"name": "Payment", "lifecycle": lifecycle}],
            "payments": {
                "provider": "Payments", "initiate": "Payments::Payment.Initiate",
                "succeeded": "Payments::Payment.PaymentGateway.Succeeded",
                "failed": "Payments::Payment.PaymentGateway.Failed", "aggregate": "Payments::Payment"
            }
        })
    }

    #[test]
    fn lifecycle_mark_reads_the_declared_states() {
        let ir = payments_ir(Some(serde_json::json!({"holds_seat": ["pending", "paid"]})));
        assert_eq!(lifecycle_mark(&ir, "Payments::Payment", "holds_seat"), Some(vec!["pending".to_string(), "paid".to_string()]));
        assert_eq!(lifecycle_mark(&ir, "Payments::Payment", "other"), None);
        assert_eq!(lifecycle_mark(&ir, "Payments::Missing", "holds_seat"), None);
        assert_eq!(lifecycle_mark(&ir, "Elsewhere::Payment", "holds_seat"), None);
        assert_eq!(lifecycle_mark(&payments_ir(None), "Payments::Payment", "holds_seat"), None);
    }

    #[test]
    fn payments_provider_uses_the_declared_holds_seat_mark() {
        let ir = payments_ir(Some(serde_json::json!({"holds_seat": ["pending", "paid"]})));
        assert_eq!(payments_provider(&ir).expect("payments").holds_seat, vec!["pending", "paid"]);
    }

    #[test]
    fn payments_provider_falls_back_to_the_legacy_default_without_the_mark() {
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
        assert_eq!(registrations_provider(&fixture_ir()), Some(RegistrationsProvider::conventional("CheckoutFixture")));
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
