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
/// `#[allow(dead_code)]` — no call site YET reads this list generically
/// (auth.rs's own Member handling still names `"member"` directly,
/// deliberately: it is auth/session plumbing, not generic dispatch, so
/// forcing a lookup through here would be artificial). This exists as
/// the real, tested, documented seam a future generic caller (a second
/// hand-integrated aggregate beyond Member, or a coverage/ops tool that
/// wants to enumerate what this deployment can lineage-read) builds on
/// without re-deriving `ir.json`'s own shape — see journal.rs's own
/// header on `read_lineage_head_all`/`_by_id` for the read half this
/// list is meant to drive call sites of.
#[allow(dead_code)]
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
}
