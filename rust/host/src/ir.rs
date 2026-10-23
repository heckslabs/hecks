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
    let domain_name = domain_ir
        .get("name")
        .and_then(|v| v.as_str())
        .unwrap_or_default();
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
/// `refuse_unsupported_persistence_adapters` below. Must list the same names
/// as [`BACKENDS`] (a test holds them together).
pub const SUPPORTED_PERSISTENCE_ADAPTERS: &[&str] = &["Postgres", "PostgresEra"];

/// What serves a bound adapter inside this host.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Backend {
    /// The one `tokio_postgres` engine (journal tables, era heads).
    TokioPostgres,
}

/// The host's implemented backends, adapter name -> backend. A future backend
/// is one more row here (and one in [`SUPPORTED_PERSISTENCE_ADAPTERS`]).
pub const BACKENDS: &[(&str, Backend)] = &[
    ("Postgres", Backend::TokioPostgres),
    ("PostgresEra", Backend::TokioPostgres),
];

/// The backend that serves `adapter`, if the host has one.
pub fn backend_for(adapter: &str) -> Option<Backend> {
    BACKENDS
        .iter()
        .find(|(name, _)| *name == adapter)
        .map(|(_, backend)| *backend)
}

/// The port every persistence binding must be declared against.
const PERSISTENCE_PORT: &str = "persistence";

/// `ir.json`'s own `adapters` key, as `name -> declaration`. `None` when the
/// key is absent (an older IR); `Some(Err(..))` when present but malformed
/// (not an array, or an entry without a string `name`).
pub fn adapter_declarations(
    domain_ir: &Value,
) -> Option<Result<std::collections::BTreeMap<String, &Value>, String>> {
    let raw = domain_ir.get("adapters")?;
    let Some(entries) = raw.as_array() else {
        return Some(Err(
            "the IR's \"adapters\" key is not an array of adapter declarations".to_string(),
        ));
    };
    let mut declared = std::collections::BTreeMap::new();
    for (index, entry) in entries.iter().enumerate() {
        match entry.get("name").and_then(|n| n.as_str()) {
            Some(name) => {
                declared.insert(name.to_string(), entry);
            }
            None => {
                return Some(Err(format!(
                    "the IR's \"adapters\" entry {index} has no string \"name\""
                )))
            }
        }
    }
    Some(Ok(declared))
}

/// The chapter this domain's role checks resolve against, read from
/// `ir.json`'s own `authorization` key. `None` when nothing provides it.
#[derive(Debug, Clone, PartialEq, Eq)]
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
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MembershipProvider {
    /// Chapter name, e.g. `Membership`.
    pub provider: String,
    /// Qualified aggregate, e.g. `Membership::Person`.
    pub aggregate: String,
}

/// Aggregates whose mutations mirror into their era head: the lineage-capable
/// ones plus the membership aggregate, which is not itself lineage-capable.
pub fn mirrored_aggregates(domain_ir: &Value) -> std::collections::BTreeSet<String> {
    let mut mirrored: std::collections::BTreeSet<String> = lineage_capable_aggregates(domain_ir)
        .into_iter()
        .map(|(qualified, _)| qualified)
        .collect();
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
#[derive(Debug, Clone, PartialEq, Eq)]
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

/// Refuses a `.world` that names a persistence adapter the host has no backend for: the world's
/// default adapter and every `persisted_by` binding. An IR without a `world` key is not checked.
pub fn refuse_unsupported_world(domain_ir: &Value) -> Result<(), String> {
    let Some(world) = domain_ir.get("world") else {
        return Ok(());
    };
    let default = world.get("default_adapter").and_then(|v| v.as_str());
    let bound = world
        .get("persistence")
        .and_then(|v| v.as_array())
        .into_iter()
        .flatten()
        .filter_map(|binding| binding.get("adapter")?.as_str());
    let unsupported: Vec<&str> = default
        .into_iter()
        .chain(bound)
        .filter(|adapter| backend_for(adapter).is_none())
        .collect();
    if unsupported.is_empty() {
        return Ok(());
    }
    Err(format!(
        "rust/host only has a backend for {SUPPORTED_PERSISTENCE_ADAPTERS:?} today; this domain's \
         world names: {}. Refusing instead of persisting somewhere the world did not choose.",
        unsupported.join(", ")
    ))
}

/// Refuses at boot rather than silently building a second, disjoint history
/// nothing but this runtime reads while the real state lives elsewhere.
///
/// Each aggregate's bound adapter is looked up in the IR, then in the host's
/// [`BACKENDS`] table. Rules, in order:
/// 1. When the IR carries an `adapters` key (even empty), the bound adapter
///    must be declared there.
/// 2. That declaration's `port`, when non-null, must be `"persistence"`.
/// 3. The adapter must have a host backend (the long-standing refusal).
///
/// Compatibility: deployed IR files predate the `adapters` key. When it is
/// absent, rules 1 and 2 are skipped and only rule 3 applies, exactly as
/// before. A present-but-malformed `adapters` value is refused with a
/// message naming the problem (it never panics).
pub fn refuse_unsupported_persistence_adapters(domain_ir: &Value) -> Result<(), String> {
    refuse_unsupported_world(domain_ir)?;
    let bindings = persistence_adapters(domain_ir);
    if let Some(declared) = adapter_declarations(domain_ir) {
        let declared = declared?;
        for (aggregate, adapter) in &bindings {
            let Some(declaration) = declared.get(adapter) else {
                return Err(format!(
                    "{aggregate} binds {adapter}, which the domain's IR does not declare (no \
                     .adapter file declares it) — refusing instead of guessing what it means"
                ));
            };
            match declaration.get("port") {
                None | Some(Value::Null) => {}
                Some(Value::String(port)) if port == PERSISTENCE_PORT => {}
                Some(port) => {
                    return Err(format!(
                        "{aggregate} binds {adapter}, which the domain's IR declares for port \
                         {port} rather than {PERSISTENCE_PORT:?} — refusing a persistence \
                         binding to a non-persistence adapter"
                    ))
                }
            }
        }
    }
    let unsupported: Vec<String> = bindings
        .into_iter()
        .filter(|(_, adapter)| backend_for(adapter).is_none())
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
        let expected: std::collections::BTreeSet<String> = ["Shop::Order", "Membership::Person"]
            .into_iter()
            .map(String::from)
            .collect();
        assert_eq!(mirrored_aggregates(&ir), expected);
    }

    #[test]
    fn mirrored_aggregates_is_just_the_capable_ones_when_no_chapter_provides_membership() {
        let ir = serde_json::json!({
            "name": "Shop",
            "lineage": { "capable_aggregates": [{ "name": "Order", "storage_name": "order" }] }
        });
        let expected: std::collections::BTreeSet<String> =
            std::iter::once("Shop::Order").map(String::from).collect();
        assert_eq!(mirrored_aggregates(&ir), expected);
        assert!(mirrored_aggregates(&serde_json::json!({ "name": "Banking" })).is_empty());
    }

    #[test]
    fn lineage_capable_aggregates_is_empty_for_a_domain_with_no_lineage_key() {
        let ir = serde_json::json!({ "name": "Banking" });
        assert_eq!(
            lineage_capable_aggregates(&ir),
            Vec::<(String, String)>::new()
        );
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
        assert!(
            err.contains("Account"),
            "error should name the offending aggregate: {err}"
        );
        assert!(
            err.contains("Heki"),
            "error should name the unsupported adapter: {err}"
        );
    }

    #[test]
    fn a_world_naming_an_unsupported_adapter_is_refused() {
        let ir = serde_json::json!({"world": {"default_adapter": "Heki", "default_database": false, "persistence": []}});
        assert!(refuse_unsupported_world(&ir).unwrap_err().contains("Heki"));
        let bound = serde_json::json!({"world": {"default_adapter": null, "default_database": false,
            "persistence": [{"adapter": "Sqlite", "settings": []}]}});
        assert!(refuse_unsupported_world(&bound)
            .unwrap_err()
            .contains("Sqlite"));
    }

    #[test]
    fn a_supported_or_absent_world_passes() {
        let ok = serde_json::json!({"world": {"default_adapter": "PostgresEra", "default_database": true,
            "persistence": [{"adapter": "Postgres", "settings": []}]}});
        assert!(refuse_unsupported_world(&ok).is_ok());
        assert!(refuse_unsupported_world(&serde_json::json!({"name": "X"})).is_ok());
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

    fn bound(adapters: &[(&str, &str)]) -> Value {
        let aggregates: Vec<Value> = adapters
            .iter()
            .map(|(n, a)| serde_json::json!({"name": n, "adapter": a}))
            .collect();
        serde_json::json!({"persistence": {"aggregates": aggregates}})
    }

    fn with_adapters(mut ir: Value, adapters: Value) -> Value {
        ir["adapters"] = adapters;
        ir
    }

    #[test]
    fn backend_table_matches_the_supported_names() {
        let names: Vec<&str> = BACKENDS.iter().map(|(n, _)| *n).collect();
        assert_eq!(names, SUPPORTED_PERSISTENCE_ADAPTERS);
    }

    #[test]
    fn absent_adapters_key_keeps_the_old_behaviour() {
        assert!(refuse_unsupported_persistence_adapters(&bound(&[("A", "Postgres")])).is_ok());
        let err = refuse_unsupported_persistence_adapters(&bound(&[("A", "Heki")])).unwrap_err();
        assert!(err.starts_with("rust/host only has a backend"), "{err}");
    }

    #[test]
    fn declared_and_supported_boots_with_null_or_persistence_port() {
        let ir = with_adapters(
            bound(&[("A", "Postgres"), ("B", "PostgresEra")]),
            serde_json::json!([
                {"name": "Postgres", "port": "persistence"},
                {"name": "PostgresEra", "port": null}
            ]),
        );
        assert!(refuse_unsupported_persistence_adapters(&ir).is_ok());
    }

    #[test]
    fn empty_adapters_key_refuses_every_binding_as_undeclared() {
        let ir = with_adapters(bound(&[("A", "Postgres")]), serde_json::json!([]));
        let err = refuse_unsupported_persistence_adapters(&ir).unwrap_err();
        assert!(
            err.contains("A binds Postgres, which the domain's IR does not declare"),
            "{err}"
        );
    }

    #[test]
    fn declared_but_unsupported_hits_the_backend_rule() {
        let ir = with_adapters(
            bound(&[("A", "Heki")]),
            serde_json::json!([{"name": "Heki", "port": "persistence"}]),
        );
        let err = refuse_unsupported_persistence_adapters(&ir).unwrap_err();
        assert!(err.starts_with("rust/host only has a backend"), "{err}");
        assert!(err.contains("A (persisted_by \"Heki\")"), "{err}");
    }

    #[test]
    fn wrong_port_is_refused_before_the_backend_rule() {
        let ir = with_adapters(
            bound(&[("A", "Postgres")]),
            serde_json::json!([{"name": "Postgres", "port": "mail"}]),
        );
        let err = refuse_unsupported_persistence_adapters(&ir).unwrap_err();
        assert!(
            err.contains("A binds Postgres") && err.contains("\"mail\""),
            "{err}"
        );
    }

    #[test]
    fn malformed_adapters_are_refused_not_panicked() {
        for bad in [
            serde_json::json!("x"),
            serde_json::json!({"name": "Postgres"}),
            serde_json::json!([{"port": "persistence"}]),
            serde_json::json!([null, 3]),
        ] {
            let ir = with_adapters(bound(&[("A", "Postgres")]), bad);
            let err = refuse_unsupported_persistence_adapters(&ir).unwrap_err();
            assert!(err.contains("\"adapters\""), "{err}");
        }
    }
}

#[cfg(test)]
#[path = "boundary_fuzz/ir.rs"]
mod boundary_fuzz;
