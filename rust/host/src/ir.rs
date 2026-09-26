// **The IR sidecar, loaded once** — `HECKS_IR_PATH` points at the same
// `ir.json` `bin/project_rust` already writes beside `metadata.rs` for a
// domain's own generated module (rust/project/domain_generator.rb's own
// header on why this exists as a plain file at all: this crate has no
// path dependency on the kernel crate that embeds the same JSON as a
// Rust constant, `metadata.rs`'s own `IR_JSON`). Shared between web.rs
// and dispatch-adjacent callers, both of which need this exact
// `OnceLock` for the identical reason.

use serde_json::Value;
use std::sync::OnceLock;

pub fn ir() -> Option<&'static Value> {
    static IR: OnceLock<Option<Value>> = OnceLock::new();
    IR.get_or_init(|| {
        let path = std::env::var("HECKS_IR_PATH").ok()?;
        let text = std::fs::read_to_string(path).ok()?;
        serde_json::from_str(&text).ok()
    })
    .as_ref()
}

/// The `(qualified_aggregate, storage_name)` pairs `Exporter.lineage`
/// (lib/hecks/projector/exporter.rb) exported for this domain — a
/// binding fact, not part of an aggregate's own canonical shape (see
/// that method's own header for why), which is exactly why it rides in
/// `ir.json` as its own top-level `lineage` key rather than nested
/// under `aggregates`. `domain_ir["name"]` qualifies each bare aggregate
/// name the same way `Store::instances`'s own keys already are
/// (`"Domain::Aggregate#id"`), so a caller can build one of those
/// directly off this list without re-deriving the domain name itself.
///
/// Empty (never an error) for a domain with no `lineage` key at all —
/// every domain generated before this existed, and every domain with
/// nothing bound to a lineage-capable adapter, look identical here: no
/// aggregate qualifies, same as today.
///
/// **A real call site** — `auth::membership_aggregate` (auth.rs) resolves
/// `ir.json`'s own `membership` key (`Exporter.membership` / a chapter's
/// `provides "membership"`) against this list to pick which
/// lineage-capable aggregate auth.rs's own Member-handling functions
/// (`member_row_by_email`/`member_rows`/`append_member_state`/
/// `session_for_member_by_identity`) actually read/write, rather than a
/// literal `"member"`/`"Member"`. This list itself
/// is still generic over every lineage-capable aggregate a domain
/// declares — `membership_aggregate` is the first, but not the only
/// possible, caller that narrows it down to one.
pub fn lineage_capable_aggregates(domain_ir: &Value) -> Vec<(String, String)> {
    let domain_name = domain_ir.get("name").and_then(|v| v.as_str()).unwrap_or_default();
    domain_ir
        .get("lineage")
        .and_then(|l| l.get("capable_aggregates"))
        .and_then(|v| v.as_array())
        .map(|entries| {
            entries
                .iter()
                .filter_map(|entry| {
                    let name = entry.get("name")?.as_str()?;
                    let storage_name = entry.get("storage_name")?.as_str()?;
                    Some((format!("{domain_name}::{name}"), storage_name.to_string()))
                })
                .collect()
        })
        .unwrap_or_default()
}

/// Every aggregate's declared persistence adapter name — `Exporter.
/// persistence` (exporter.rb), a binding fact like `lineage` above, not
/// part of an aggregate's own canonical shape, riding in `ir.json` as
/// its own top-level `persistence` key. Unlike `lineage_capable_
/// aggregates`, this covers every aggregate a domain declares, not just
/// the lineage-capable ones — `rust/host` has exactly one backend
/// (Postgres/PostgresEra, `journal.rs`/`dispatch.rs`), and an aggregate
/// bound to anything else (Heki, Memory, Sqlite, D1, LocalStorage) is
/// invisible to it: no adapter/backend trait exists here to even notice
/// the mismatch. See `refuse_unsupported_persistence_adapters` below,
/// the actual consumer.
pub fn persistence_adapters(domain_ir: &Value) -> Vec<(String, String)> {
    domain_ir
        .get("persistence")
        .and_then(|p| p.get("aggregates"))
        .and_then(|v| v.as_array())
        .map(|entries| {
            entries
                .iter()
                .filter_map(|entry| {
                    let name = entry.get("name")?.as_str()?;
                    let adapter = entry.get("adapter")?.as_str()?;
                    Some((name.to_string(), adapter.to_string()))
                })
                .collect()
        })
        .unwrap_or_default()
}

/// The only persistence adapters `rust/host` has a real backend for
/// today. Anything else bound in a domain's own `.world` is a silent
/// gap, not a loud one, without this check — see the function below.
pub const SUPPORTED_PERSISTENCE_ADAPTERS: &[&str] = &["Postgres", "PostgresEra"];

/// Refuses loudly, at boot, if this domain binds any aggregate to a
/// persistence adapter `rust/host` cannot actually serve — closing a
/// silent-wrongness gap found by direct trace: examples/banking binds
/// every aggregate to `Heki` (a local flock+journal file store,
/// lib/hecks/adapters/driven/heki.rb), which `rust/host` has never had
/// any code path for. Without this check, `main.rs` boots clean
/// regardless (Heki is never lineage-capable, so the era/lineage gate
/// above skips silently too) and `dispatch::handle` proceeds straight
/// into its own flat Postgres rehydrate-replay path against
/// `hecks_lambda_journal`/`hecks_lambda_snapshot` — tables seeded empty
/// for a domain whose real state lives entirely in `.heki` files this
/// runtime never opens. The result is silent state bifurcation: two
/// independent, diverging histories for the same nominal domain, with
/// no error anywhere — a request rust/host serves could report
/// "not found" for an account Ruby's own store has always had, or
/// accept a create Ruby would refuse as a duplicate. Refusing at boot
/// instead trades that for a loud, immediate, correct failure.
/// The chapter this domain's role checks resolve against — `Exporter.
/// authorization` (exporter.rb), a binding fact like `lineage`/
/// `persistence` above, read off `ir.json`'s own top-level
/// `authorization` key. `None` when the domain attaches nothing that
/// declares `provides "authorization"` (the key is omitted entirely).
#[derive(Debug, Clone, PartialEq)]
pub struct AuthorizationProvider {
    /// Qualified grant command, e.g. `Governance::RoleAssignment.Assign`.
    pub grant: String,
    /// Qualified aggregate holding the assignments, e.g.
    /// `Governance::RoleAssignment` — instance keys start `<this>#`.
    pub assignment_aggregate: String,
}

pub fn authorization_provider(domain_ir: &Value) -> Option<AuthorizationProvider> {
    let fact = domain_ir.get("authorization")?;
    Some(AuthorizationProvider {
        grant: fact.get("grant")?.as_str()?.to_string(),
        assignment_aggregate: fact.get("assignment_aggregate")?.as_str()?.to_string(),
    })
}

/// The chapter that answers "who may sign in" — `Exporter.membership`
/// (exporter.rb), a binding fact like `authorization` above, read off
/// `ir.json`'s own top-level `membership` key. `None` when the domain
/// attaches nothing that declares `provides "membership"` (the key is
/// omitted entirely). Replaces the former HECKS_MEMBERSHIP_AGGREGATE
/// env var: the aggregate is named by what the chapter declares, not
/// by a deploy-time string.
#[derive(Debug, Clone, PartialEq)]
pub struct MembershipProvider {
    /// Chapter name, e.g. `Membership`.
    pub provider: String,
    /// Qualified aggregate, e.g. `Membership::Person`.
    pub aggregate: String,
}

/// The aggregates whose dispatched mutations mirror into their era head:
/// the lineage-capable ones, plus the membership aggregate. Boot mints the
/// membership aggregate's head so sign-in can read it, but a vendored
/// chapter's aggregate is not in `lineage.capable_aggregates`, so without
/// it here a command dispatched on it (a Membership `translates`, such as
/// a signup's Admit and GrantAccess) would never reach that head. The
/// membership name is the chapter's qualified name, which is what a kernel
/// mutation record carries.
pub fn mirrored_aggregates(domain_ir: &Value) -> std::collections::BTreeSet<String> {
    let mut mirrored: std::collections::BTreeSet<String> =
        lineage_capable_aggregates(domain_ir).into_iter().map(|(qualified, _)| qualified).collect();
    if let Some(membership) = membership_provider(domain_ir) {
        mirrored.insert(membership.aggregate);
    }
    mirrored
}

pub fn membership_provider(domain_ir: &Value) -> Option<MembershipProvider> {
    let fact = domain_ir.get("membership")?;
    Some(MembershipProvider {
        provider: fact.get("provider")?.as_str()?.to_string(),
        aggregate: fact.get("aggregate")?.as_str()?.to_string(),
    })
}

/// The chapter that answers "who is this authenticated pair" —
/// `Exporter.identity` (exporter.rb), a binding fact like `authorization`
/// above, read off `ir.json`'s own top-level `identity` key. `None` when
/// the domain attaches nothing that declares `provides "identity"`.
/// Breaking in 2.0: Link's reference field is `identity`, never
/// `identity_id` and never `to:`.
#[derive(Debug, Clone, PartialEq)]
pub struct IdentityProvider {
    /// Chapter name, e.g. `Identity`.
    pub provider: String,
    /// Qualified register command, e.g. `Identity::Identity.Register`.
    pub register: String,
    /// Qualified link command, e.g. `Identity::ExternalIdentifier.Link`.
    pub link: String,
    /// Qualified resolve query, e.g. `Identity::ExternalIdentifier.ResolvedBy`.
    pub resolve: String,
}

pub fn identity_provider(domain_ir: &Value) -> Option<IdentityProvider> {
    let fact = domain_ir.get("identity")?;
    Some(IdentityProvider {
        provider: fact.get("provider")?.as_str()?.to_string(),
        register: fact.get("register")?.as_str()?.to_string(),
        link: fact.get("link")?.as_str()?.to_string(),
        resolve: fact.get("resolve")?.as_str()?.to_string(),
    })
}

/// The chapter that answers the guest newsletter signup —
/// `Exporter.newsletter` (exporter.rb), a binding fact like `membership`
/// above, read off `ir.json`'s own top-level `newsletter` key. `None` when
/// the domain attaches nothing that declares `provides "newsletter"` (the
/// key is omitted entirely), so a domain without it serves no newsletter
/// routes.
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
/// named `field`. Lets a route send an optional extra argument only to a
/// domain whose command actually takes it: a command refuses an argument it
/// does not declare.
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

/// The chapter that declares `provides "newsletter_issues"`, read from the
/// IR's `newsletter_issues` key (which `bin/project_rust` omits entirely when
/// nothing declares it), so a domain without it serves no send route.
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


/// The chapter that takes payments — `Exporter.payments` (exporter.rb), a
/// binding fact like `newsletter` above, read off `ir.json`'s own top-level
/// `payments` key. `None` when the domain attaches nothing that declares
/// `provides "payments"` (the key is omitted entirely), so a domain without
/// it serves no checkout, registration-payment or webhook routes.
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
    Some(PaymentsProvider {
        provider: fact.get("provider")?.as_str()?.to_string(),
        initiate: fact.get("initiate")?.as_str()?.to_string(),
        succeeded: fact.get("succeeded")?.as_str()?.to_string(),
        failed: fact.get("failed")?.as_str()?.to_string(),
        aggregate: fact.get("aggregate")?.as_str()?.to_string(),
    })
}

/// The chapter that answers scheduling sessions and taking registrations —
/// `Exporter.registrations` (exporter.rb), read off `ir.json`'s own top-level
/// `registrations` key. `None` when nothing the domain attaches declares
/// `provides "registrations"` (the key is omitted entirely).
#[derive(Debug, Clone, PartialEq)]
pub struct RegistrationsProvider {
    /// Chapter name, e.g. `Lifeadelics`.
    pub provider: String,
    /// Qualified schedule command, e.g. `Lifeadelics::Event.Schedule`.
    pub schedule: String,
    /// Qualified request command, e.g. `Lifeadelics::Registration.Request`.
    pub request: String,
    /// Qualified event aggregate, e.g. `Lifeadelics::Event`.
    pub event_aggregate: String,
    /// Qualified registration aggregate, e.g. `Lifeadelics::Registration`.
    pub registration_aggregate: String,
}

impl RegistrationsProvider {
    /// The names a domain has when it calls its own aggregates `Event` and
    /// `Registration` and declares no `provides "registrations"` yet — what
    /// this host used before the capability existed, kept as the fallback so
    /// a domain that has not declared it keeps working.
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
    /// starts with, e.g. `Lifeadelics::Event#`.
    pub fn event_prefix(&self) -> String {
        format!("{}#", self.event_aggregate)
    }

    /// The prefix every registration's key starts with, e.g.
    /// `Lifeadelics::Registration#`.
    pub fn registration_prefix(&self) -> String {
        format!("{}#", self.registration_aggregate)
    }

    /// The request command's own aggregate and command name without the
    /// chapter qualifier, e.g. `("Registration", "Request")` — the shape
    /// `command_declares` looks a command up by in the domain's own IR.
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
/// conventional names for `domain` when the IR declares none (or none is
/// loaded).
pub fn registrations_binding(domain: &str) -> RegistrationsProvider {
    ir().and_then(registrations_provider).unwrap_or_else(|| RegistrationsProvider::conventional(domain))
}

/// One command of the payment-processor connection, by the role it plays —
/// resolved to the declaring chapter's own command name through
/// `PaymentConnectionProvider::verb`.
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

/// The chapter that owns the business's payment-processor connection —
/// `Exporter.payment_connection` (exporter.rb), read off `ir.json`'s own
/// top-level `payment_connection` key. `None` when nothing the domain
/// attaches declares `provides "payment_connection"`.
#[derive(Debug, Clone, PartialEq)]
pub struct PaymentConnectionProvider {
    /// Chapter name, e.g. `Lifeadelics`.
    pub provider: String,
    pub connect: String,
    pub reconnect: String,
    pub disconnect: String,
    pub suspend: String,
    pub resume: String,
    pub enable: String,
    pub disable: String,
    /// Qualified connection aggregate, e.g. `Lifeadelics::PaymentConnection`.
    pub aggregate: String,
}

impl PaymentConnectionProvider {
    /// The names a domain has when it calls its connection aggregate
    /// `PaymentConnection` with the commands this host used before the
    /// capability existed, kept as the fallback.
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
    /// map starts with, e.g. `Lifeadelics::PaymentConnection#`.
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
/// conventional names for `domain` when the IR declares none (or none is
/// loaded).
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

pub fn refuse_unsupported_persistence_adapters(domain_ir: &Value) -> Result<(), String> {
    let unsupported: Vec<String> = persistence_adapters(domain_ir)
        .into_iter()
        .filter(|(_, adapter)| !SUPPORTED_PERSISTENCE_ADAPTERS.contains(&adapter.as_str()))
        .map(|(name, adapter)| format!("{name} (persisted_by {adapter:?})"))
        .collect();
    if unsupported.is_empty() {
        return Ok(());
    }
    Err(format!(
        "rust/host only has a backend for {SUPPORTED_PERSISTENCE_ADAPTERS:?} today; this domain \
         also binds: {}. Dispatching against it here would silently build a second, disjoint \
         history nothing but this runtime ever reads, while the real state stays wherever its own \
         adapter actually wrote it — refusing instead of risking that.",
        unsupported.join(", ")
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lineage_capable_aggregates_qualifies_names_with_the_domain() {
        let ir = serde_json::json!({
            "name": "Pizzas",
            "lineage": { "capable_aggregates": [{ "name": "Order", "storage_name": "order" }] }
        });
        assert_eq!(
            lineage_capable_aggregates(&ir),
            vec![("Pizzas::Order".to_string(), "order".to_string())]
        );
    }

    #[test]
    fn mirrored_aggregates_adds_a_vendored_membership_aggregate_to_the_capable_ones() {
        let ir = serde_json::json!({
            "name": "Shop",
            "lineage": { "capable_aggregates": [{ "name": "Order", "storage_name": "order" }] },
            "membership": { "provider": "Membership", "aggregate": "Membership::Person" }
        });
        let expected: std::collections::BTreeSet<String> =
            ["Shop::Order", "Membership::Person"].into_iter().map(String::from).collect();
        assert_eq!(mirrored_aggregates(&ir), expected);
    }

    #[test]
    fn mirrored_aggregates_is_just_the_capable_ones_when_no_chapter_provides_membership() {
        let ir = serde_json::json!({
            "name": "Shop",
            "lineage": { "capable_aggregates": [{ "name": "Order", "storage_name": "order" }] }
        });
        let expected: std::collections::BTreeSet<String> = ["Shop::Order"].into_iter().map(String::from).collect();
        assert_eq!(mirrored_aggregates(&ir), expected);
        assert!(mirrored_aggregates(&serde_json::json!({ "name": "Banking" })).is_empty());
    }

    #[test]
    fn lineage_capable_aggregates_is_empty_for_a_domain_with_no_lineage_key() {
        let ir = serde_json::json!({ "name": "Banking" });
        assert_eq!(lineage_capable_aggregates(&ir), Vec::<(String, String)>::new());
    }

    #[test]
    fn persistence_adapters_reads_every_declared_aggregate() {
        let ir = serde_json::json!({
            "name": "Banking",
            "persistence": { "aggregates": [
                { "name": "Account", "storage_name": "account", "adapter": "Heki" },
                { "name": "Transfer", "storage_name": "transfer", "adapter": "Heki" }
            ] }
        });
        assert_eq!(
            persistence_adapters(&ir),
            vec![
                ("Account".to_string(), "Heki".to_string()),
                ("Transfer".to_string(), "Heki".to_string())
            ]
        );
    }

    #[test]
    fn persistence_adapters_is_empty_for_a_domain_with_no_persistence_key() {
        let ir = serde_json::json!({ "name": "Pizzas" });
        assert_eq!(persistence_adapters(&ir), Vec::<(String, String)>::new());
    }

    #[test]
    fn refuse_unsupported_persistence_adapters_passes_postgres_and_postgres_era() {
        let ir = serde_json::json!({
            "name": "Pizzas",
            "persistence": { "aggregates": [
                { "name": "Order", "storage_name": "order", "adapter": "PostgresEra" }
            ] }
        });
        assert!(refuse_unsupported_persistence_adapters(&ir).is_ok());
    }

    #[test]
    fn refuse_unsupported_persistence_adapters_refuses_heki_by_name() {
        let ir = serde_json::json!({
            "name": "Banking",
            "persistence": { "aggregates": [
                { "name": "Account", "storage_name": "account", "adapter": "Heki" }
            ] }
        });
        let err = refuse_unsupported_persistence_adapters(&ir).unwrap_err();
        assert!(err.contains("Account"), "error should name the offending aggregate: {err}");
        assert!(err.contains("Heki"), "error should name the unsupported adapter: {err}");
    }

    #[test]
    fn membership_provider_reads_the_declared_capability() {
        let ir = serde_json::json!({
            "name": "Studio",
            "membership": { "provider": "Membership", "aggregate": "Membership::Person" }
        });
        let provider = membership_provider(&ir).expect("should find membership");
        assert_eq!(provider.provider, "Membership");
        assert_eq!(provider.aggregate, "Membership::Person");
        assert!(membership_provider(&serde_json::json!({ "name": "Pizzas" })).is_none());
    }

    #[test]
    fn identity_provider_reads_the_declared_capability() {
        let ir = serde_json::json!({
            "name": "Studio",
            "identity": {
                "provider": "Identity",
                "register": "Identity::Identity.Register",
                "link": "Identity::ExternalIdentifier.Link",
                "resolve": "Identity::ExternalIdentifier.ResolvedBy"
            }
        });
        let provider = identity_provider(&ir).expect("should find identity");
        assert_eq!(provider.provider, "Identity");
        assert_eq!(provider.register, "Identity::Identity.Register");
        assert_eq!(provider.link, "Identity::ExternalIdentifier.Link");
        assert_eq!(provider.resolve, "Identity::ExternalIdentifier.ResolvedBy");
        assert!(identity_provider(&serde_json::json!({ "name": "Pizzas" })).is_none());
    }

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

    #[test]
    fn refuse_unsupported_persistence_adapters_passes_a_domain_with_no_persistence_key() {
        let ir = serde_json::json!({ "name": "Pizzas" });
        assert!(refuse_unsupported_persistence_adapters(&ir).is_ok());
    }
}
