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
            "name": "Lifeadelics",
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
            "name": "Lifeadelics",
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
    fn refuse_unsupported_persistence_adapters_passes_a_domain_with_no_persistence_key() {
        let ir = serde_json::json!({ "name": "Pizzas" });
        assert!(refuse_unsupported_persistence_adapters(&ir).is_ok());
    }
}
