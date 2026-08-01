//! Detects when a bluebook's storage shape has drifted from what its
//! data was written under — a rename or restructure with nothing to
//! explain it. Refuses at boot, before a command can run into the gap.
//! Mirrors lib/hecksagain/runtime/era_guard.rb, with one simplification
//! Rust's architecture affords for free: `crate::bluebook::parser::parse`
//! is a pure function with no registry side effects, so re-parsing held
//! text needs no scratch-registry dance at all.

use crate::bluebook::translation::ir::Translation;
use crate::ir::{Aggregate, Attribute, Domain};
use crate::ports::persistence::Lineage;
use std::fs;
use std::path::Path;

pub fn check(domain: &Domain, translations: &[Translation], domain_root: &Path, current_text: &str) -> Result<(), String> {
    let era_dir = domain_root.join("data").join("eras");
    let held_path = era_dir.join(format!("{}.bluebook", crate::naming::snake(&domain.name)));

    fs::create_dir_all(&era_dir).map_err(|error| format!("cannot create {}: {error}", era_dir.display()))?;

    if !held_path.exists() {
        fs::write(&held_path, current_text)
            .map_err(|error| format!("cannot write {}: {error}", held_path.display()))?;
        return Ok(());
    }

    let held_text = fs::read_to_string(&held_path)
        .map_err(|error| format!("cannot read {}: {error}", held_path.display()))?;
    let held_domain = crate::bluebook::parser::parse(&held_text);

    let mut drifted = false;

    for aggregate in &domain.aggregates {
        let lineage = Lineage::for_aggregate(translations, &domain.name, &aggregate.name);
        let ancestor_name = lineage.as_ref().and_then(|lineage| lineage.ancestor_name.clone());
        let held_name = ancestor_name.as_deref().unwrap_or(&aggregate.name);
        let Some(held_aggregate) = held_domain.aggregates.iter().find(|held| held.name == *held_name) else {
            continue;
        };

        if shape(aggregate) == shape(held_aggregate) {
            continue;
        }
        drifted = true;

        let uncovered = uncovered_attributes(aggregate, held_aggregate, lineage.as_ref());
        if uncovered.is_empty() {
            continue;
        }

        let joined = uncovered.iter().map(|path| render_path(path)).collect::<Vec<_>>().join(", ");
        let verb = if uncovered.len() == 1 { "is" } else { "are" };
        return Err(format!(
            "cannot boot {}::{}: its shape changed and {} {} not explained by any rename, move, convert, retype, or drop. \
             Update bluebook/translations/*.bluebook, e.g. {}.",
            domain.name, aggregate.name, joined, verb, suggestion(&uncovered[0])
        ));
    }

    check_vanished_aggregates(domain, translations, &held_domain)?;

    if drifted {
        fs::write(&held_path, current_text)
            .map_err(|error| format!("cannot write {}: {error}", held_path.display()))?;
    }

    Ok(())
}

/// An aggregate that existed in the held text and answers to no current
/// name — renamed silently, with nothing declaring `was:` to explain
/// where its data went — is exactly the disease this guards against, and
/// a plain per-aggregate diff would never see it: the current aggregate
/// simply has no held counterpart to compare to.
fn check_vanished_aggregates(domain: &Domain, translations: &[Translation], held_domain: &Domain) -> Result<(), String> {
    for held_aggregate in &held_domain.aggregates {
        let mut claimed = domain.aggregates.iter().any(|aggregate| {
            aggregate.name == held_aggregate.name
                || translations.iter().any(|translation| {
                    translation.domain == domain.name
                        && translation
                            .for_aggregate(&aggregate.name)
                            .and_then(|declared| declared.was.as_deref())
                            == Some(held_aggregate.name.as_str())
                })
        });
        claimed = claimed
            || translations.iter().any(|translation| {
                translation.domain == domain.name && translation.retired.iter().any(|name| name == &held_aggregate.name)
            });
        if claimed {
            continue;
        }
        return Err(format!(
            "cannot boot {}: {} existed and now doesn't, and nothing declares was: {:?} to explain where its data went.",
            domain.name, held_aggregate.name, held_aggregate.name
        ));
    }
    Ok(())
}

/// Paths the translation needs to explain: attributes that vanished by
/// name, attributes that kept their name but changed type (a `convert`
/// is what lets that be declared at all), and — recursing into a
/// same-named, same-typed value object — its OWN members vanishing or
/// changing type one level down, reported as a dotted path
/// ("price.currency"). A pure addition, at any depth, never needs
/// covering; only vanish-or-retype does, matching the top-level rule at
/// every depth. Preserves the held aggregate's own declaration order,
/// matching the Ruby port, so a multi-field refusal message reads
/// identically in both runtimes.
fn uncovered_attributes(aggregate: &Aggregate, held_aggregate: &Aggregate, lineage: Option<&Lineage>) -> Vec<String> {
    let paths: Vec<String> = held_aggregate
        .attributes
        .iter()
        .flat_map(|held_attribute| {
            let Some(current_attribute) = aggregate.attributes.iter().find(|a| a.name == held_attribute.name) else {
                return vec![held_attribute.name.clone()];
            };
            diff_type(
                &held_attribute.name,
                &held_attribute.r#type,
                &current_attribute.r#type,
                held_aggregate,
                aggregate,
                lineage,
                &[],
            )
        })
        .collect();

    match lineage {
        None => paths,
        Some(lineage) => paths.into_iter().filter(|path| !lineage.explains(path)).collect(),
    }
}

/// `held_type`/`current_type` are type NAMES, resolved against each
/// side's OWN value_object AND entity declarations — neither is ever
/// nested in the DSL, only in the type graph, so both are always looked
/// up flat off their respective aggregate. A `list_of` entity is only
/// reached here to DETECT a member vanish-or-retype; there is no
/// per-element translation machinery yet (`move`/`convert`/`drop` only
/// reach into a single nested hash, not each element of an array) — the
/// only way to satisfy a refusal on an entity path today is a top-level
/// `drop` of the whole list attribute, which `explains` already
/// recognizes as covering everything nested under it. Blunt, but loud
/// beats silent.
#[allow(clippy::too_many_arguments)]
fn diff_type(
    path: &str,
    held_type: &str,
    current_type: &str,
    held_aggregate: &Aggregate,
    aggregate: &Aggregate,
    lineage: Option<&Lineage>,
    seen: &[String],
) -> Vec<String> {
    if held_type != current_type {
        // A declared retype says the two TYPE names mean the same shape
        // — accept the pair, but still recurse into the members so a
        // member drift hiding beneath the rename is caught by name.
        if !lineage.is_some_and(|lineage| lineage.retype_covers(held_type, current_type)) {
            return vec![path.to_string()];
        }
    }
    if seen.iter().any(|s| s == current_type) {
        return vec![];
    }

    let held_members = find_nested_attributes(held_aggregate, held_type);
    let current_members = find_nested_attributes(aggregate, current_type);
    let (Some(held_members), Some(current_members)) = (held_members, current_members) else {
        return vec![];
    };

    let mut next_seen = seen.to_vec();
    next_seen.push(current_type.to_string());

    held_members
        .iter()
        .flat_map(|held_member| {
            let member_path = format!("{path}.{}", held_member.name);
            let Some(current_member) = current_members.iter().find(|a| a.name == held_member.name) else {
                return vec![member_path];
            };
            diff_type(&member_path, &held_member.r#type, &current_member.r#type, held_aggregate, aggregate, lineage, &next_seen)
        })
        .collect()
}

/// A value object's or an entity's own attribute list — both expose the
/// same shape, so one lookup covers `attribute :price, Money` and
/// `attribute :ledger, list_of(LedgerEntry)` identically.
fn find_nested_attributes<'a>(aggregate: &'a Aggregate, type_name: &str) -> Option<&'a [Attribute]> {
    if let Some(value_object) = aggregate.value_objects.iter().find(|vo| vo.name == type_name) {
        return Some(&value_object.attributes);
    }
    aggregate.entities.iter().find(|entity| entity.name == type_name).map(|entity| entity.attributes.as_slice())
}

fn shape(aggregate: &Aggregate) -> Vec<(String, AttributeSignature)> {
    let mut pairs: Vec<(String, AttributeSignature)> =
        aggregate.attributes.iter().map(|attribute| (attribute.name.clone(), attribute_signature(aggregate, &attribute.r#type, &[]))).collect();
    pairs.sort_by(|a, b| a.0.cmp(&b.0));
    pairs
}

/// A plain type name for a primitive; a type name plus its members'
/// signatures for a value object or entity, walked recursively — so two
/// attributes with the same declared type name but a different internal
/// shape are never mistaken for unchanged.
#[derive(Debug, Clone, PartialEq, Eq)]
enum AttributeSignature {
    Plain(String),
    Nested(String, Vec<(String, AttributeSignature)>),
}

fn attribute_signature(aggregate: &Aggregate, type_name: &str, seen: &[String]) -> AttributeSignature {
    let Some(members) = find_nested_attributes(aggregate, type_name) else {
        return AttributeSignature::Plain(type_name.to_string());
    };
    if seen.iter().any(|s| s == type_name) {
        return AttributeSignature::Plain(type_name.to_string());
    }

    let mut next_seen = seen.to_vec();
    next_seen.push(type_name.to_string());

    let mut signatures: Vec<(String, AttributeSignature)> =
        members.iter().map(|member| (member.name.clone(), attribute_signature(aggregate, &member.r#type, &next_seen))).collect();
    signatures.sort_by(|a, b| a.0.cmp(&b.0));

    AttributeSignature::Nested(type_name.to_string(), signatures)
}

fn render_path(path: &str) -> String {
    if path.contains('.') {
        format!("{path:?}")
    } else {
        format!(":{path}")
    }
}

fn suggestion(path: &str) -> String {
    if path.contains('.') {
        format!("`move {path:?}, to: {path:?}` or `drop {path:?}`")
    } else {
        format!("`rename :{path}, to: :new_name` or `drop :{path}`")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    const V1: &str = r#"
Hecks.bluebook "Guarded" do
  aggregate "Account" do
    attribute :balance, Money

    value_object "Money" do
      attribute :cents, Integer
    end
  end
end
"#;

    const RETYPED: &str = r#"
Hecks.bluebook "Guarded" do
  aggregate "Account" do
    attribute :balance, Cash

    value_object "Cash" do
      attribute :cents, Integer
    end
  end
end
"#;

    const GONE: &str = r#"
Hecks.bluebook "Guarded" do
  aggregate "Vault" do
  end
end
"#;

    fn temp_root(label: &str) -> PathBuf {
        let path = std::env::temp_dir().join(format!("hecksagain-era-guard-{label}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&path);
        fs::create_dir_all(&path).unwrap();
        path
    }

    fn check_era(label: &str, current: &str, translation_source: Option<&str>) -> Result<(), String> {
        let root = temp_root(label);
        let v1 = crate::bluebook::parser::parse(V1);
        check(&v1, &[], &root, V1).unwrap();

        let drifted = crate::bluebook::parser::parse(current);
        let translations: Vec<Translation> = translation_source
            .map(|source| vec![crate::bluebook::translation::parser::parse(source).unwrap()])
            .unwrap_or_default();
        let verdict = check(&drifted, &translations, &root, current);
        let _ = fs::remove_dir_all(&root);
        verdict
    }

    #[test]
    fn a_bare_type_rename_refuses_and_names_retype_among_the_remedies() {
        let refusal = check_era("bare-retype", RETYPED, None).unwrap_err();
        assert_eq!(
            refusal,
            "cannot boot Guarded::Account: its shape changed and :balance is not explained by any \
             rename, move, convert, retype, or drop. Update bluebook/translations/*.bluebook, e.g. \
             `rename :balance, to: :new_name` or `drop :balance`."
        );
    }

    #[test]
    fn a_declared_retype_covers_the_type_name_pair() {
        let edge = r#"
Hecks.data_translation "Guarded", from: "1", to: "2" do
  aggregate "Account" do
    retype "Money", to: "Cash"
  end
end
"#;
        check_era("covered-retype", RETYPED, Some(edge)).unwrap();
    }

    #[test]
    fn a_vanished_aggregate_refuses_unless_retired_declares_it_gone() {
        let refusal = check_era("vanished", GONE, None).unwrap_err();
        assert_eq!(
            refusal,
            "cannot boot Guarded: Account existed and now doesn't, and nothing declares was: \"Account\" \
             to explain where its data went."
        );

        let edge = r#"
Hecks.data_translation "Guarded", from: "1", to: "2" do
  retired "Account"
end
"#;
        check_era("retired", GONE, Some(edge)).unwrap();
    }
}
