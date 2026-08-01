//! The boot-time capability gate — twin of
//! lib/hecksagain/runtime/era_check.rb.
//!
//! Eras belong to the adapters that HAVE them: an era is a fact about
//! stored data some adapter can carry across a shape change, and an
//! adapter that cannot translate has no era to hold. The lineage-capable
//! adapter keeps its era facts as rows beside its data and runs its own
//! gate (see the dispatcher's boot path); nothing here holds anything.
//!
//! What survives adapter-agnostically is the per-rule compute check,
//! which was never an era fact — see below. Wordings are byte-identical
//! with the Ruby side.

use crate::bluebook::translation::ir::Translation;
use crate::ir::Domain;
use crate::ports::persistence::Lineage;
use std::collections::BTreeMap;

pub struct EraContext<'a> {
    pub domain: &'a Domain,
    pub translations: &'a [Translation],
    /// aggregate name → declared adapter name (the authoritative bind).
    pub adapters: &'a BTreeMap<String, String>,
    /// aggregate name → whether its bound adapter declares the lineage
    /// capability (only Postgres does today).
    pub capable: &'a BTreeMap<String, bool>,
}

/// The per-rule capability gate — NOT an era fact, and so it runs for
/// every adapter: a compute rule's SQL is its only implementation, so
/// an aggregate carrying one cannot boot anywhere but Postgres,
/// whatever any shape comparison would say.
pub fn check_compute_rules(context: &EraContext) -> Result<(), String> {
    for aggregate in &context.domain.aggregates {
        let lineage = Lineage::for_aggregate(context.translations, &context.domain.name, &aggregate.name);
        let carries_compute = lineage.as_ref().is_some_and(Lineage::has_computes);
        if !carries_compute {
            continue;
        }
        if context.capable.get(&aggregate.name).copied().unwrap_or(false) {
            continue;
        }
        let adapter = adapter_name(context, &aggregate.name);
        return Err(format!(
            "compute rules require the Postgres adapter; {} is bound to {}",
            aggregate.name, adapter
        ));
    }
    Ok(())
}

fn adapter_name(context: &EraContext, aggregate: &str) -> String {
    context
        .adapters
        .get(aggregate)
        .cloned()
        .unwrap_or_else(|| crate::ports::persistence::DEFAULT_ADAPTER.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::path::PathBuf;

    fn fixture(name: &str) -> String {
        let path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../spec/fixtures/eras").join(name);
        fs::read_to_string(path).unwrap()
    }

    /// Byte-identical with spec/era_check_spec.rb — the same fixture,
    /// the same refusal string, so a wording drift in either runtime
    /// fails a suite.
    #[test]
    fn refuses_a_compute_rule_per_rule_and_by_name() {
        let source = fixture("base.bluebook");
        let domain = crate::bluebook::parser::parse(&source);
        let adapters: BTreeMap<String, String> =
            domain.aggregates.iter().map(|a| (a.name.clone(), "Memory".to_string())).collect();
        let capable: BTreeMap<String, bool> = domain.aggregates.iter().map(|a| (a.name.clone(), false)).collect();
        let edge = crate::bluebook::translation::parser::parse(
            "Hecks.data_translation \"Shaped\", from: \"1\", to: \"2\" do\n  aggregate \"Account\" do\n    compute \"price_cents\", to: \"price_dollars\", sql: \"price_cents::numeric / 100\"\n  end\nend\n",
        )
        .unwrap();
        let translations = [edge];

        let refusal = check_compute_rules(&EraContext {
            domain: &domain,
            translations: &translations,
            adapters: &adapters,
            capable: &capable,
        })
        .unwrap_err();
        assert_eq!(refusal, "compute rules require the Postgres adapter; Account is bound to Memory");
    }
}
