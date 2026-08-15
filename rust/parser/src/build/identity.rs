//! Mirrors `AttributeCollector#resolve_identity_field!`/
//! `#resolve_identity_type!` (`lib/hecksagain/bluebook/dsl/attribute_collector.rb`)
//! — the two DERIVING forms of `identified_by`:
//!
//!   `identified_by :field, :field_two` — the LIVE form (ADR 0025,
//!                                        "Identity"), one or more.
//!                                        Each field's own already-
//!                                        declared attribute decides the
//!                                        shape: a reference resolves
//!                                        bare (already a scalar); a
//!                                        single-field value object
//!                                        auto-unwraps to
//!                                        `field.<that attribute>`; a
//!                                        bare primitive resolves
//!                                        unchanged. A list, or a value
//!                                        object with more than one
//!                                        field, refuses.
//!   `identified_by ValueObject, as: field` — LEGACY (Ruby: only under
//!                                        `MetaValidator.shadow_parsing?`
//!                                        — history predating this
//!                                        removal, S0a's own bridge).
//!                                        No live corpus member uses it
//!                                        any more; kept here since
//!                                        Rust's own corpus never
//!                                        needed the live/legacy split
//!                                        Ruby's shadow-parse draws.
//!                                        Mirrors `reference_to`'s own
//!                                        shape: the attribute itself is
//!                                        MINTED (name is `as:` or
//!                                        `Naming.snake(type)`),
//!                                        requires the value object to
//!                                        have exactly one field.
//!
//! The third form — `identified_by { name.value }`, a `source`-shaped
//! block — is NOT a derivation at all: its body IS the identity path,
//! captured as raw text and canonicalized (canonical.rs), never resolved
//! against already-declared attributes the way the two blockless forms
//! are. That's why it lives in parse/*.rs's body-gate handling rather
//! than here.

use crate::diag::{Diagnostic, ParseResult};
use crate::ir;

/// `AttributeCollector#resolve_identity_field!` — the bare-field form,
/// `identified_by :field` (one or more, composite identity is their
/// JOIN). `field`'s own already-declared attribute decides the shape:
/// a reference is already a scalar (resolves bare, unchanged) ; a
/// single-field value object auto-unwraps to `field.<that field>` ; a
/// bare primitive resolves unchanged too. A list, or a value object
/// with more than one field, refuses.
///
/// `:id` OR AN `_id`-SUFFIXED NAME WITH NO MATCHING ATTRIBUTE is not a
/// typo to refuse — it is the language's own WALK-PARENT/FALLBACK-
/// IDENTITY convention (the meta-domain's own `Command`/`Entity`/
/// `Aggregate` etc. identify by `owner_id`/`bluebook_id`/`aggregate_id`,
/// supplied by the judge's replay rather than declared locally; bare
/// `:id` is `Instance#materialize_identity!`'s own fallback name made
/// explicit). Mirrors Ruby's own comment on this exact branch,
/// `attribute_collector.rb`.
pub fn resolve_identity_field(file: &str, line: usize, context_name: &str, field: &str, value_objects: &[ir::ValueObject], attributes: &[ir::Attribute]) -> ParseResult<String> {
    let attr = attributes.iter().find(|a| a.name == field);

    let attr = match attr {
        Some(attr) => attr,
        None if field == "id" || field.ends_with("_id") => return Ok(field.to_string()),
        None => {
            return Err(Diagnostic::new(file, line, format!("{context_name}.identified_by :{field} names no attribute {context_name} declares")));
        }
    };

    if attr.list {
        return Err(Diagnostic::new(
            file,
            line,
            format!("{context_name}.identified_by :{field} names a list — an identity must be a single value, and a list is never one"),
        ));
    }

    if attr.type_name.starts_with("Reference<") {
        return Ok(field.to_string());
    }

    let Some(vo) = value_objects.iter().find(|v| v.name == attr.type_name) else {
        return Ok(field.to_string()); // a bare primitive type — already itself scalar
    };

    match vo.attributes.len() {
        1 => Ok(format!("{field}.{}", vo.attributes[0].name)),
        n => {
            let names: Vec<String> = vo.attributes.iter().map(|a| a.name.clone()).collect();
            Err(Diagnostic::new(
                file,
                line,
                format!(
                    "{context_name}.identified_by :{field} names {}, which has {n} fields ({}) — a bare field \
                     name only derives an identity when its own value object has exactly one field; give \
                     {context_name} a single-field identity of its own instead",
                    attr.type_name,
                    names.join(", ")
                ),
            ))
        }
    }
}

/// `AttributeCollector#resolve_identity_type!` — `identified_by
/// ValueObject, as: field`. Confirmed real: pizzas.bluebook's own
/// `identified_by PizzaName, as: :name` (line 8), resolved at the END of
/// the aggregate's body (mirroring Ruby's own build-time deferral —
/// `PizzaName` is declared LATER in the file, after `identified_by`
/// itself), not at the point `identified_by` was written.
///
/// Mints the identity attribute at `insert_at` (the attribute count AT
/// THE MOMENT `identified_by` was called — 0 for pizzas.bluebook, since
/// it is the very first line of the aggregate body) and returns the
/// single derived identity path, `"<field>.<value object's sole field>"`.
#[allow(clippy::too_many_arguments)]
pub fn resolve_identity_type(
    file: &str,
    line: usize,
    context_name: &str,
    target: &str,
    as_field: Option<&str>,
    insert_at: usize,
    value_objects: &[ir::ValueObject],
    attributes: &mut Vec<ir::Attribute>,
) -> ParseResult<Vec<String>> {
    let target = crate::build::naming::demodulise(target);
    let vo = value_objects.iter().find(|v| v.name == target).ok_or_else(|| {
        Diagnostic::new(file, line, format!("{context_name}.identified_by names {target}, which is not a declared value object"))
    })?;

    if vo.attributes.len() != 1 {
        let names: Vec<String> = vo.attributes.iter().map(|a| a.name.clone()).collect();
        return Err(Diagnostic::new(
            file,
            line,
            format!(
                "{context_name}.identified_by names {target}, which has {} fields ({}) — identified_by \
                 ValueObject only derives a path when it has exactly one field; write identified_by \
                 {{ field.<field> }} naming the specific one",
                vo.attributes.len(),
                names.join(", ")
            ),
        ));
    }

    let field = as_field.map(|s| s.to_string()).unwrap_or_else(|| crate::build::naming::snake(&target));
    let sole_field = vo.attributes[0].name.clone();

    let minted = ir::Attribute { name: field.clone(), type_name: target, list: false, ..Default::default() };
    let insert_at = insert_at.min(attributes.len());
    attributes.insert(insert_at, minted);

    Ok(vec![format!("{field}.{sole_field}")])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn derives_a_single_path_from_a_one_field_value_object() {
        let mut attributes = vec![ir::Attribute { name: "pizza".to_string(), type_name: "Pizza".to_string(), ..Default::default() }];
        let value_objects = vec![ir::ValueObject {
            name: "PizzaName".to_string(),
            attributes: vec![ir::Attribute { name: "value".to_string(), type_name: "String".to_string(), ..Default::default() }],
            ..Default::default()
        }];

        let paths =
            resolve_identity_type("f.bluebook", 1, "Order", "PizzaName", Some("name"), 0, &value_objects, &mut attributes).unwrap();

        assert_eq!(paths, vec!["name.value".to_string()]);
        assert_eq!(attributes[0].name, "name");
        assert_eq!(attributes[0].type_name, "PizzaName");
        assert_eq!(attributes[1].name, "pizza");
    }

    #[test]
    fn refuses_a_value_object_with_more_than_one_field() {
        let mut attributes = Vec::new();
        let value_objects = vec![ir::ValueObject {
            name: "Pizza".to_string(),
            attributes: vec![
                ir::Attribute { name: "price_cents".to_string(), type_name: "Price".to_string(), ..Default::default() },
                ir::Attribute { name: "size".to_string(), type_name: "Size".to_string(), ..Default::default() },
            ],
            ..Default::default()
        }];

        let err = resolve_identity_type("f.bluebook", 1, "Order", "Pizza", None, 0, &value_objects, &mut attributes).unwrap_err();
        assert!(err.message.contains("2 fields"));
    }
}
