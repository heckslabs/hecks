// The IR sidecar, loaded once from `HECKS_IR_PATH`: this crate has no path
// dependency on the kernel crate that embeds the same JSON as `IR_JSON`.

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

/// Aggregates bound to a lineage-capable adapter, as `(qualified_name,
/// storage_name)` — read from `ir.json`'s own `lineage` key.
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

/// Every aggregate's declared persistence adapter, as `(name, adapter)` —
/// read from `ir.json`'s own `persistence` key.
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

/// The only persistence adapters `rust/host` has a real backend for — see
/// `refuse_unsupported_persistence_adapters` below.
pub const SUPPORTED_PERSISTENCE_ADAPTERS: &[&str] = &["Postgres", "PostgresEra"];

/// The chapter this domain's role checks resolve against, read from
/// `ir.json`'s own `authorization` key. `None` when nothing provides it.
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

/// The chapter that answers "who may sign in", read from `ir.json`'s own
/// `membership` key. `None` when nothing provides `"membership"`.
#[derive(Debug, Clone, PartialEq)]
pub struct MembershipProvider {
    /// Chapter name, e.g. `Membership`.
    pub provider: String,
    /// Qualified aggregate, e.g. `Membership::Person`.
    pub aggregate: String,
}

/// Aggregates whose mutations mirror into their era head: the lineage-capable
/// ones plus the membership aggregate, which is not itself lineage-capable.
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

/// The chapter that answers "who is this authenticated pair", read from
/// `ir.json`'s own `identity` key. `None` when nothing provides `"identity"`.
/// Link's reference field must stay `identity` — never `identity_id`, never `to:`.
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

/// Refuses at boot rather than silently building a second, disjoint history
/// nothing but this runtime reads while the real state lives elsewhere.
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
    fn refuse_unsupported_persistence_adapters_passes_a_domain_with_no_persistence_key() {
        let ir = serde_json::json!({ "name": "Pizzas" });
        assert!(refuse_unsupported_persistence_adapters(&ir).is_ok());
    }
}

#[cfg(test)]
#[path = "boundary_fuzz/ir.rs"]
mod boundary_fuzz;
