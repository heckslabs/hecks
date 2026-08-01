//! The boot-time era gate — twin of lib/hecksagain/runtime/era_check.rb,
//! run for EVERY adapter: hold the bluebook source at the first boot of
//! an era, compare the current text's storage-shape projection against
//! the held eras structurally on every boot after that, and refuse
//! loudly the moment the shape has drifted under an adapter that cannot
//! act on drift. Detection and identity are separate jobs: this check
//! never hashes anything — era names come from the store, already
//! minted (by the Ruby scaffold) or absent. Wordings are byte-identical
//! with the Ruby side.

use crate::bluebook::translation::ir::Translation;
use crate::ir::Domain;
use crate::ports::persistence::{EraStore, Lineage};
use crate::runtime::storage_shape;
use serde_json::Value;
use std::collections::BTreeMap;
use std::path::Path;

pub struct EraContext<'a> {
    pub domain: &'a Domain,
    pub translations: &'a [Translation],
    /// aggregate name → declared adapter name (the authoritative bind).
    pub adapters: &'a BTreeMap<String, String>,
    /// aggregate name → whether its bound adapter declares the lineage
    /// capability (only Postgres ever will).
    pub capable: &'a BTreeMap<String, bool>,
}

pub fn check(context: &EraContext, root: &Path, current_text: &str) -> Result<(), String> {
    check_compute_rules(context)?;

    let store = EraStore::new(root, &context.domain.name);
    let held = store.held_texts()?;
    let current_shape = storage_shape::project(context.domain);
    if held.is_empty() {
        return store.hold_first(current_text, Some(&current_shape));
    }
    let shapes: Vec<(u32, Value)> = held
        .iter()
        .map(|(ordinal, text)| (*ordinal, storage_shape::project(&crate::bluebook::parser::parse(text))))
        .collect();

    let (latest_ordinal, latest_shape) = shapes.last().expect("held is non-empty");
    if *latest_shape == current_shape {
        return Ok(());
    }

    let matched = shapes.iter().find(|(_, shape)| *shape == current_shape).map(|(ordinal, _)| *ordinal);
    refuse(context, &current_shape, latest_shape, &store, matched, *latest_ordinal)
}

/// The per-rule capability gate, checked before the general drift
/// machinery says anything vaguer: a compute rule's SQL is its only
/// implementation, so an aggregate carrying one cannot boot anywhere
/// but Postgres — even before any shape comparison happens. Public so
/// the lineage-capable boot path (which skips the file store entirely)
/// still runs it for any NON-capable aggregate sharing the domain.
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

fn refuse(
    context: &EraContext,
    current_shape: &Value,
    latest_shape: &Value,
    store: &EraStore,
    matched: Option<u32>,
    latest: u32,
) -> Result<(), String> {
    let subject = drifted_subject(context.domain, current_shape, latest_shape);
    if context.capable.get(&subject).copied().unwrap_or(false) {
        return Ok(());
    }
    let adapter = adapter_name(context, &subject);

    if let Some(matched) = matched {
        return Err(format!(
            "cannot boot {subject}: this is era {matched}'s shape, which era {latest} superseded, \
             and {adapter} cannot serve a superseded era — bind Postgres, or reset the data"
        ));
    }

    let era = latest + 1;
    let named = store.label_for(era).map(|label| format!(", {label}")).unwrap_or_default();
    Err(format!(
        "cannot boot {subject}: the shape changed (era {era}{named}) \
         and {adapter} cannot translate — bind Postgres, or reset the data"
    ))
}

/// The refusal names the first place the shape actually moved: the
/// first current aggregate (declaration order) whose projection differs
/// from its held counterpart — or, when only a vanished aggregate
/// distinguishes the two eras, the vanished one, since it is its data
/// that stands to be stranded.
fn drifted_subject(domain: &Domain, current_shape: &Value, latest_shape: &Value) -> String {
    let by_name = |shape: &Value| -> BTreeMap<String, Value> {
        shape
            .get("aggregates")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default()
            .into_iter()
            .filter_map(|aggregate| {
                let name = aggregate.get("name").and_then(Value::as_str)?.to_string();
                Some((name, aggregate))
            })
            .collect()
    };
    let held = by_name(latest_shape);
    let current = by_name(current_shape);

    for aggregate in &domain.aggregates {
        if held.get(&aggregate.name) != current.get(&aggregate.name) {
            return aggregate.name.clone();
        }
    }
    held.keys()
        .find(|name| !current.contains_key(*name))
        .cloned()
        .unwrap_or_else(|| domain.name.clone())
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

    fn temp_root(label: &str) -> PathBuf {
        let path = std::env::temp_dir().join(format!("hecksagain-era-check-{label}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&path);
        fs::create_dir_all(&path).unwrap();
        path
    }

    fn run_check(root: &Path, source: &str, translations: &[Translation]) -> Result<(), String> {
        let domain = crate::bluebook::parser::parse(source);
        let adapters: BTreeMap<String, String> =
            domain.aggregates.iter().map(|a| (a.name.clone(), "Memory".to_string())).collect();
        let capable: BTreeMap<String, bool> = domain.aggregates.iter().map(|a| (a.name.clone(), false)).collect();
        check(
            &EraContext { domain: &domain, translations, adapters: &adapters, capable: &capable },
            root,
            source,
        )
    }

    /// Byte-identical with spec/era_check_spec.rb — the same fixtures,
    /// the same refusal strings, so a wording drift in either runtime
    /// fails a suite.
    #[test]
    fn holds_first_then_boots_quietly_and_never_bumps_on_behavior() {
        let root = temp_root("quiet");
        let base = fixture("base.bluebook");

        run_check(&root, &base, &[]).unwrap();
        let held = root.join("data/eras/shaped/1.bluebook");
        assert_eq!(fs::read_to_string(&held).unwrap(), base);

        run_check(&root, &base, &[]).unwrap();
        run_check(&root, &fixture("same_behavior.bluebook"), &[]).unwrap();
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn refuses_drift_with_the_capability_refusal_naming_the_era() {
        let root = temp_root("drift");
        run_check(&root, &fixture("base.bluebook"), &[]).unwrap();

        let refusal = run_check(&root, &fixture("bump_attribute_rename.bluebook"), &[]).unwrap_err();
        assert_eq!(
            refusal,
            "cannot boot Account: the shape changed (era 2) and Memory cannot translate — bind Postgres, or reset the data"
        );

        // Once the Ruby scaffold has minted era 2's name, the refusal
        // carries it — read from the store, never recomputed here.
        fs::write(root.join("data/eras/shaped/names.tsv"), "2\tdeadbeef00\tdeadbe\n").unwrap();
        let refusal = run_check(&root, &fixture("bump_attribute_rename.bluebook"), &[]).unwrap_err();
        assert_eq!(
            refusal,
            "cannot boot Account: the shape changed (era 2, deadbe) and Memory cannot translate — bind Postgres, or reset the data"
        );
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn recognizes_a_revert_as_the_superseded_era_s_shape() {
        let root = temp_root("revert");
        run_check(&root, &fixture("base.bluebook"), &[]).unwrap();
        fs::write(root.join("data/eras/shaped/2.bluebook"), fixture("bump_attribute_rename.bluebook")).unwrap();

        let refusal = run_check(&root, &fixture("base.bluebook"), &[]).unwrap_err();
        assert_eq!(
            refusal,
            "cannot boot Account: this is era 1's shape, which era 2 superseded, and Memory cannot serve a superseded era — bind Postgres, or reset the data"
        );
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn refuses_a_held_text_edited_after_it_was_frozen_and_says_which_situation() {
        let root = temp_root("tamper");
        run_check(&root, &fixture("base.bluebook"), &[]).unwrap();

        // a shape-changing edit — byte-identical with the Ruby verdict
        fs::write(root.join("data/eras/shaped/1.bluebook"), fixture("bump_attribute_rename.bluebook")).unwrap();
        let refusal = run_check(&root, &fixture("base.bluebook"), &[]).unwrap_err();
        assert_eq!(
            refusal,
            "cannot boot Shaped: the held text of era 1 was edited after it was frozen AND the edit changed the storage shape — re-attestation will refuse it; restore the original text from the era archive"
        );

        // a cosmetic edit — same projection, re-attestation is the remedy
        fs::write(
            root.join("data/eras/shaped/1.bluebook"),
            format!("# an operator fixed a typo\n{}", fixture("base.bluebook")),
        )
        .unwrap();
        let refusal = run_check(&root, &fixture("base.bluebook"), &[]).unwrap_err();
        assert_eq!(
            refusal,
            "cannot boot Shaped: the held text of era 1 was edited after it was frozen — the edit is cosmetic to the storage shape; re-attest it (bin/reattest_era), or restore the original text from the era archive"
        );

        // the archive holds the original bytes; restoring them boots again
        let archived: Vec<_> = fs::read_dir(root.join("data/eras/shaped/archive"))
            .unwrap()
            .filter_map(Result::ok)
            .map(|entry| entry.path())
            .collect();
        assert_eq!(archived.len(), 1);
        assert_eq!(fs::read_to_string(&archived[0]).unwrap(), fixture("base.bluebook"));
        fs::copy(&archived[0], root.join("data/eras/shaped/1.bluebook")).unwrap();
        run_check(&root, &fixture("base.bluebook"), &[]).unwrap();

        // a missing digest backfills rather than refusing
        fs::remove_file(root.join("data/eras/shaped/integrity.tsv")).unwrap();
        run_check(&root, &fixture("base.bluebook"), &[]).unwrap();
        assert!(root.join("data/eras/shaped/integrity.tsv").exists());
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn refuses_a_compute_rule_per_rule_and_by_name_before_drift() {
        let root = temp_root("compute");
        let edge = crate::bluebook::translation::parser::parse(
            "Hecks.data_translation \"Shaped\", from: \"1\", to: \"2\" do\n  aggregate \"Account\" do\n    compute \"price_cents\", to: \"price_dollars\", sql: \"price_cents::numeric / 100\"\n  end\nend\n",
        )
        .unwrap();

        let refusal = run_check(&root, &fixture("base.bluebook"), &[edge]).unwrap_err();
        assert_eq!(refusal, "compute rules require the Postgres adapter; Account is bound to Memory");
        let _ = fs::remove_dir_all(&root);
    }
}
