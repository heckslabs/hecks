//! Mirrors `AttributeCollector#resolve_identity_field!`/
//! `#resolve_identity_type!` (`lib/hecksagain/bluebook/dsl/attribute_collector.rb`)
//! — the two DERIVING forms of `identified_by`:
//!
//!   `identified_by :field`            — the bare-field form. `field`'s
//!                                        already-declared attribute names
//!                                        a value object; when that value
//!                                        object holds EXACTLY one
//!                                        attribute, the path is
//!                                        `field.<that attribute>`. More
//!                                        than one field is refused,
//!                                        naming every candidate.
//!   `identified_by ValueObject, as: field` — the bare-type form, mirrors
//!                                        `reference_to`'s own shape: the
//!                                        attribute itself is MINTED (name
//!                                        is `as:` or `Naming.snake(type)`),
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
