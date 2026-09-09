// THE IR SIDECAR, LOADED ONCE — `HECKS_IR_PATH` points at the SAME
// `ir.json` `bin/project_rust` already writes beside `metadata.rs` for a
// domain's own generated module (rust/project/domain_generator.rb's own
// header on why this exists as a plain file at all: this crate has no
// path dependency on the kernel crate that embeds the same JSON as a
// Rust constant, `metadata.rs`'s own `IR_JSON`). Pulled out of web.rs
// (which used to hold its own private copy of this exact `OnceLock`)
// because dispatch-adjacent callers need it too now, for the identical
// reason web.rs already did.

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
/// BINDING fact, not part of an aggregate's own canonical shape (see
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
/// NO LONGER DEAD CODE — `auth::membership_aggregate` (auth.rs) is the
/// real call site this comment used to say didn't exist yet: it resolves
/// `HECKS_MEMBERSHIP_AGGREGATE` against this list to pick which
/// lineage-capable aggregate auth.rs's own Member-handling functions
/// (`member_row_by_email`/`member_rows`/`append_member_state`/
/// `session_for_member_by_identity`) actually read/write, instead of the
/// literal `"member"`/`"Member"` they used to hardcode. This list itself
/// is still generic over EVERY lineage-capable aggregate a domain
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
/// persistence` (exporter.rb), a BINDING fact like `lineage` above, not
/// part of an aggregate's own canonical shape, riding in `ir.json` as
/// its own top-level `persistence` key. Unlike `lineage_capable_
/// aggregates`, this covers EVERY aggregate a domain declares, not just
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
/// `hecks_lambda_journal`/`hecks_lambda_snapshot` — tables seeded EMPTY
/// for a domain whose real state lives entirely in `.heki` files this
/// runtime never opens. The result is silent state bifurcation: two
/// independent, diverging histories for the same nominal domain, with
/// no error anywhere — a request rust/host serves could report
/// "not found" for an account Ruby's own store has always had, or
/// accept a create Ruby would refuse as a duplicate. Refusing at boot
/// instead trades that for a loud, immediate, correct failure.
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
    fn refuse_unsupported_persistence_adapters_passes_a_domain_with_no_persistence_key() {
        let ir = serde_json::json!({ "name": "Pizzas" });
        assert!(refuse_unsupported_persistence_adapters(&ir).is_ok());
    }
}
