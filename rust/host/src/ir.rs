// The IR sidecar, installed once by boot from the file `HECKS_IR_PATH` names: this crate has no
// path dependency on the kernel crate that embeds the same JSON as `IR_JSON`.

use serde_json::Value;
use std::sync::OnceLock;

static IR: OnceLock<Option<Value>> = OnceLock::new();
static SCHEMAS: OnceLock<Option<Value>> = OnceLock::new();

/// The JSON Schema of the command `Aggregate/Command`, from the `schemas.json` the build writes
/// beside the IR; `None` when no schemas were installed or the command has none.
pub fn command_schema(aggregate: &str, command: &str) -> Option<&'static Value> {
    SCHEMAS
        .get()
        .and_then(Option::as_ref)?
        .get(format!("{aggregate}/{command}"))
}

/// Reads the schemas file beside the IR file at `ir_path` (`<name>.ir.json` -> `<name>.schemas.json`);
/// a missing or unreadable file installs none, and a command then has no schema to serve.
pub fn install_schemas(ir_path: Option<&str>) {
    SCHEMAS.get_or_init(|| {
        let path = ir_path?.strip_suffix(".ir.json")?.to_string() + ".schemas.json";
        serde_json::from_str(&std::fs::read_to_string(path).ok()?).ok()
    });
}

/// The domain's IR, or `None` when nothing has been installed or the installed file was missing,
/// unreadable or not JSON.
pub fn ir() -> Option<&'static Value> {
    IR.get().and_then(Option::as_ref)
}

/// Reads and parses the IR file at `path` for [`ir`] to answer; `None` installs no IR. Only the
/// first call has an effect, so the IR is fixed for the life of the process.
pub fn install(path: Option<&str>) {
    IR.get_or_init(|| {
        let text = std::fs::read_to_string(path?).ok()?;
        serde_json::from_str(&text).ok()
    });
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
pub const SUPPORTED_PERSISTENCE_ADAPTERS: &[&str] = &["Postgres", "PostgresEra", "Memory"];

/// The environment variable that lets the host boot on the Memory store, which keeps nothing
/// across a restart and so is for local runs and tests only.
pub const ALLOW_MEMORY_STORE: &str = "HECKS_ALLOW_MEMORY_STORE";

/// What serves a bound adapter inside this host.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Backend {
    /// The one `tokio_postgres` engine (journal tables, era heads).
    TokioPostgres,
    /// Process memory: a journal that lives and dies with the process.
    Memory,
}

impl Backend {
    /// Whether this backend offers eras and head views, which lineage-capable aggregates and
    /// member sign-in read.
    pub const fn has_lineage(self) -> bool {
        matches!(self, Self::TokioPostgres)
    }

    /// The name used in refusals.
    pub const fn name(self) -> &'static str {
        match self {
            Self::TokioPostgres => "Postgres",
            Self::Memory => "Memory",
        }
    }
}

/// The host's implemented backends, adapter name -> backend. A future backend
/// is one more row here (and one in [`SUPPORTED_PERSISTENCE_ADAPTERS`]).
pub const BACKENDS: &[(&str, Backend)] = &[
    ("Postgres", Backend::TokioPostgres),
    ("PostgresEra", Backend::TokioPostgres),
    ("Memory", Backend::Memory),
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

/// Whether the adapter the IR binds `aggregate` to declares `provides capability`: the host's
/// reading of Ruby's `Registry#adapter_provides?`. False when the aggregate is unbound, its
/// adapter is undeclared, or the IR predates the `adapters` key.
pub fn adapter_provides(domain_ir: &Value, aggregate: &str, capability: &str) -> bool {
    let bound = domain_ir
        .pointer("/persistence/aggregates")
        .and_then(Value::as_array)
        .and_then(|rows| {
            rows.iter()
                .find(|row| row.get("name").and_then(Value::as_str) == Some(aggregate))
        })
        .and_then(|row| row.get("adapter").and_then(Value::as_str));
    let Some(Some(Ok(declared))) = bound.map(|_| adapter_declarations(domain_ir)) else {
        return false;
    };
    bound
        .and_then(|name| declared.get(name))
        .and_then(|adapter| adapter.get("provides"))
        .and_then(Value::as_array)
        .is_some_and(|names| names.iter().any(|name| name.as_str() == Some(capability)))
}

/// The bluebook this domain's role checks resolve against, read from
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

/// The bluebook that answers "who may sign in", read from `ir.json`'s own
/// `membership` key. `None` when nothing provides `"membership"`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MembershipProvider {
    /// Bluebook name, e.g. `Membership`.
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

/// The bluebook that answers "who is this authenticated pair", read from
/// `ir.json`'s own `identity` key. `None` when nothing provides `"identity"`.
/// Link's reference field must stay `identity` — never `identity_id`, never `to:`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct IdentityProvider {
    /// Bluebook name, e.g. `Identity`.
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

/// Settings a world binding carries that are not adapter fields.
const WORLD_EXEMPT_SETTINGS: &[&str] = &["adapter", "role"];

fn world_error(what: &str) -> String {
    format!("the IR's \"world\" {what}")
}

fn declared_names(declaration: &Value) -> std::collections::BTreeSet<&str> {
    ["fields", "secrets"]
        .iter()
        .filter_map(|key| declaration.get(key)?.as_array())
        .flatten()
        .filter_map(|name| name.as_str())
        .collect()
}

fn check_world_binding(
    binding: &Value,
    declared: &std::collections::BTreeMap<String, &Value>,
) -> Result<(), String> {
    let adapter = binding
        .get("adapter")
        .and_then(|a| a.as_str())
        .ok_or_else(|| world_error("persistence entry has no string \"adapter\""))?;
    let settings = binding
        .get("settings")
        .and_then(|s| s.as_array())
        .ok_or_else(|| world_error("persistence entry's \"settings\" is not an array"))?;
    let Some(declaration) = declared.get(adapter) else {
        return Ok(());
    };
    let known = declared_names(declaration);
    for setting in settings {
        let name = setting
            .as_str()
            .ok_or_else(|| world_error("persistence entry has a setting that is not a string"))?;
        if !WORLD_EXEMPT_SETTINGS.contains(&name) && !known.contains(name) {
            return Err(format!(
                "{adapter} does not declare {name:?} — the world sets it, but the adapter declares \
                 {known:?}. Add the field to the adapter, or remove it from the world."
            ));
        }
    }
    Ok(())
}

/// Refuses a world that sets, on a declared persistence adapter, a setting the adapter does not
/// declare as a field or secret (`adapter` and `role` are exempt). Entries for adapters the IR's
/// `adapters` key does not declare are skipped, and an IR without a `world` key is not checked.
pub fn refuse_undeclared_world_settings(domain_ir: &Value) -> Result<(), String> {
    let Some(world) = domain_ir.get("world") else {
        return Ok(());
    };
    if !world.is_object() {
        return Err(world_error("key is not an object"));
    }
    let entries = world
        .get("persistence")
        .and_then(|p| p.as_array())
        .ok_or_else(|| world_error("\"persistence\" is not an array"))?;
    let declared = match adapter_declarations(domain_ir) {
        Some(declared) => declared?,
        None => return Ok(()),
    };
    entries
        .iter()
        .try_for_each(|binding| check_world_binding(binding, &declared))
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
    refuse_undeclared_world_settings(domain_ir)?;
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

/// Picks the one backend this domain's journal lives on, or says why it cannot boot.
///
/// 1. Every adapter must be one the host serves (see
///    [`refuse_unsupported_persistence_adapters`]).
/// 2. All the domain's aggregates must resolve to the same backend: a domain keeps one journal.
/// 3. The Memory backend needs `allow_memory`, because it is for local runs and tests.
/// 4. A backend without lineage cannot serve a domain with lineage-capable aggregates (or
///    Google sign-in, `google_auth`), which read eras and head views.
///
/// An IR with no persistence bindings (an older one) boots on Postgres, as it always did.
pub fn select_backend(
    domain_ir: &Value,
    allow_memory: bool,
    google_auth: bool,
) -> Result<Backend, String> {
    refuse_unsupported_persistence_adapters(domain_ir)?;
    let backend = single_backend(domain_ir)?;
    if backend == Backend::Memory && !allow_memory {
        return Err(format!(
            "this domain binds the Memory store, which keeps nothing across a restart and is for \
             local runs and tests only; set {ALLOW_MEMORY_STORE}=1 to boot on it, or bind a \
             durable store"
        ));
    }
    refuse_lineage_without_capability(domain_ir, backend, google_auth)?;
    Ok(backend)
}

fn single_backend(domain_ir: &Value) -> Result<Backend, String> {
    let bindings = persistence_adapters(domain_ir);
    let backends: std::collections::BTreeSet<&str> = bindings
        .iter()
        .filter_map(|(_, adapter)| backend_for(adapter))
        .map(Backend::name)
        .collect();
    if backends.len() > 1 {
        let bound: Vec<String> = bindings
            .iter()
            .map(|(aggregate, adapter)| format!("{aggregate} (persisted_by {adapter:?})"))
            .collect();
        return Err(format!(
            "this domain binds aggregates to different stores ({}); rust/host keeps one journal \
             per domain, on one backend, so bind every aggregate to the same store",
            bound.join(", ")
        ));
    }
    Ok(bindings
        .first()
        .and_then(|(_, adapter)| backend_for(adapter))
        .unwrap_or(Backend::TokioPostgres))
}

fn refuse_lineage_without_capability(
    domain_ir: &Value,
    backend: Backend,
    google_auth: bool,
) -> Result<(), String> {
    if backend.has_lineage() {
        return Ok(());
    }
    let mirrored: Vec<String> = mirrored_aggregates(domain_ir).into_iter().collect();
    if mirrored.is_empty() && !google_auth {
        return Ok(());
    }
    let needs = if mirrored.is_empty() {
        "Google sign-in".to_string()
    } else {
        format!("lineage-capable aggregates {mirrored:?}")
    };
    Err(format!(
        "this domain needs {needs}, which read eras and head views only the Postgres store \
         has; the {} store cannot serve it",
        backend.name()
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

    fn world_ir(settings: &Value) -> Value {
        serde_json::json!({
            "adapters": [{"name": "PostgresEra", "port": "persistence",
                          "fields": ["url"], "secrets": ["password"], "defaults": {}}],
            "world": {"default_adapter": null, "default_database": false,
                      "persistence": [{"adapter": "PostgresEra", "settings": settings}]}
        })
    }

    #[test]
    fn a_world_setting_the_adapter_does_not_declare_is_refused() {
        let err =
            refuse_undeclared_world_settings(&world_ir(&serde_json::json!(["bogus"]))).unwrap_err();
        assert!(
            err.contains("PostgresEra") && err.contains("bogus"),
            "{err}"
        );
    }

    #[test]
    fn declared_fields_secrets_role_and_adapter_pass() {
        let ir = world_ir(&serde_json::json!(["url", "password", "role", "adapter"]));
        assert!(refuse_undeclared_world_settings(&ir).is_ok());
    }

    #[test]
    fn an_undeclared_adapter_in_the_world_is_skipped() {
        let mut ir = world_ir(&serde_json::json!(["bogus"]));
        ir["adapters"] = serde_json::json!([]);
        assert!(refuse_undeclared_world_settings(&ir).is_ok());
    }

    #[test]
    fn an_ir_without_a_world_key_is_not_checked() {
        assert!(refuse_undeclared_world_settings(&serde_json::json!({"name": "X"})).is_ok());
    }

    #[test]
    fn a_malformed_world_is_refused() {
        let mut not_object = world_ir(&serde_json::json!([]));
        not_object["world"] = serde_json::json!("x");
        let mut not_array = world_ir(&serde_json::json!([]));
        not_array["world"]["persistence"] = serde_json::json!({});
        let bad_setting = world_ir(&serde_json::json!([3]));
        for ir in [not_object, not_array, bad_setting] {
            assert!(refuse_undeclared_world_settings(&ir).is_err());
        }
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
    fn adapter_provides_reads_the_bound_adapters_capabilities() {
        let ir = with_adapters(
            bound(&[("Ledger::Entry", "Postgres"), ("Ledger::Note", "Memory")]),
            serde_json::json!([
                {"name": "Postgres", "provides": ["set_transform"]},
                {"name": "Memory"}
            ]),
        );
        assert!(adapter_provides(&ir, "Ledger::Entry", "set_transform"));
        assert!(!adapter_provides(&ir, "Ledger::Entry", "teleport"));
        assert!(!adapter_provides(&ir, "Ledger::Note", "set_transform"));
        assert!(!adapter_provides(&ir, "Ledger::Ghost", "set_transform"));
        assert!(!adapter_provides(
            &bound(&[("Ledger::Entry", "Postgres")]),
            "Ledger::Entry",
            "set_transform"
        ));
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

    fn memory_domain() -> Value {
        with_adapters(
            bound(&[("A", "Memory"), ("B", "Memory")]),
            serde_json::json!([{"name": "Memory", "port": "persistence"}]),
        )
    }

    #[test]
    fn a_domain_with_no_persistence_bindings_boots_on_postgres() {
        let ir = serde_json::json!({ "name": "Pizzas" });
        assert_eq!(
            select_backend(&ir, false, false),
            Ok(Backend::TokioPostgres)
        );
    }

    #[test]
    fn postgres_and_postgres_era_are_one_backend() {
        let ir = bound(&[("A", "Postgres"), ("B", "PostgresEra")]);
        assert_eq!(
            select_backend(&ir, false, false),
            Ok(Backend::TokioPostgres)
        );
    }

    #[test]
    fn a_domain_binding_different_stores_is_refused() {
        let err =
            select_backend(&bound(&[("A", "Postgres"), ("B", "Memory")]), true, false).unwrap_err();
        assert!(err.contains("different stores"), "{err}");
        assert!(err.contains("A (persisted_by \"Postgres\")"), "{err}");
        assert!(err.contains("B (persisted_by \"Memory\")"), "{err}");
    }

    #[test]
    fn memory_is_refused_unless_the_opt_in_is_set() {
        let err = select_backend(&memory_domain(), false, false).unwrap_err();
        assert!(err.contains("local runs and tests only"), "{err}");
        assert!(err.contains(ALLOW_MEMORY_STORE), "{err}");
    }

    #[test]
    fn memory_boots_with_the_opt_in() {
        assert_eq!(
            select_backend(&memory_domain(), true, false),
            Ok(Backend::Memory)
        );
    }

    #[test]
    fn lineage_capable_aggregates_are_refused_on_memory() {
        let mut ir = memory_domain();
        ir["name"] = serde_json::json!("Shop");
        ir["lineage"] = serde_json::json!({
            "capable_aggregates": [{ "name": "Order", "storage_name": "order" }]
        });
        let err = select_backend(&ir, true, false).unwrap_err();
        assert!(err.contains("Shop::Order"), "{err}");
        assert!(err.contains("only the Postgres store"), "{err}");
    }

    #[test]
    fn a_membership_aggregate_is_refused_on_memory() {
        let mut ir = memory_domain();
        ir["membership"] =
            serde_json::json!({ "provider": "Membership", "aggregate": "Membership::Person" });
        let err = select_backend(&ir, true, false).unwrap_err();
        assert!(err.contains("Membership::Person"), "{err}");
    }

    #[test]
    fn google_sign_in_is_refused_on_memory() {
        let err = select_backend(&memory_domain(), true, true).unwrap_err();
        assert!(err.contains("Google sign-in"), "{err}");
    }

    #[test]
    fn lineage_on_postgres_is_not_refused() {
        let mut ir = bound(&[("A", "PostgresEra")]);
        ir["lineage"] = serde_json::json!({
            "capable_aggregates": [{ "name": "A", "storage_name": "a" }]
        });
        assert_eq!(select_backend(&ir, false, true), Ok(Backend::TokioPostgres));
    }

    #[test]
    fn an_unsupported_adapter_is_still_refused_before_a_backend_is_chosen() {
        let err = select_backend(&bound(&[("A", "Heki")]), true, false).unwrap_err();
        assert!(err.starts_with("rust/host only has a backend"), "{err}");
    }
}

#[cfg(test)]
#[path = "boundary_fuzz/ir.rs"]
mod boundary_fuzz;
