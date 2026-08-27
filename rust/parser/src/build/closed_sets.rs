//! Mirrors `AttributeCollector#synthesise_closed_set` — an inline
//! `attribute :status, one_of("open", "shut")` desugars to a value object
//! named `Naming.pascal(attribute_name)`, with one `value: String`
//! attribute and one member per listed value, `closed_set: true`. Also
//! covers `one_of do member ... end` (the standalone, named form,
//! `parse::value_object`'s own `parse_one_of_body`) and `member`'s own
//! pairs-row capture (`PairsShape::verbatim` — each member's fields are
//! an open map, never resolved against a fixed schema).
//!
//! STAGE 3: `synthesize` below, called from `parse::mod::
//! resolve_type_expression` — confirmed real by console_settings.
//! bluebook's `StateStyle.tone`/`Collection.identity_strategy`
//! (`attribute :tone, one_of("good", "warn", "danger", "muted",
//! "accent"), optional: true`).

use crate::build::naming;
use crate::ir;

/// `AttributeCollector#synthesise_closed_set` — `type = Naming.pascal(name)`,
/// one `value: String` attribute, one member per listed value
/// (`{value: value.to_s}`, `IR::ValueObject#to_h`'s own `.to_s` rendering
/// — see `ruby_value::to_s`'s own header on why that's distinct from
/// `Literal.render`). The CALLER decides whether the synthesized value
/// object actually gets kept: only `AggregateBuilder#build`'s own
/// `@value_objects + closed_sets` folds it into the owning aggregate —
/// `CommandBuilder`/`QueryBuilder`/`ValueObjectBuilder`/
/// `DomainPortBuilder` all include the SAME `AttributeCollector` module
/// and so also synthesize one for their own inline `one_of(...)`
/// attributes, but none of their own `#build` methods ever read
/// `closed_sets` — confirmed by reading each builder directly, not
/// assumed — so a command/query/value-object/port-operation attribute's
/// own synthesized value object is discarded by its caller in
/// `parse/*.rs`, keeping only the derived `type_name` string (the
/// AGGREGATE that already declares the same field name independently
/// mints the real value object other constructs' attributes merely
/// reference by name).
pub fn synthesize(field_name: &str, values: &[String]) -> ir::ValueObject {
    let type_name = naming::pascal(field_name);
    ir::ValueObject {
        name: type_name,
        attributes: vec![ir::Attribute {
            name: "value".to_string(),
            type_name: "String".to_string(),
            ..Default::default()
        }],
        invariants: Vec::new(),
        closed_set: true,
        members: values
            .iter()
            .map(|value| vec![("value".to_string(), crate::ruby_value::Value::Str(value.clone()))])
            .collect(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn synthesizes_a_pascal_named_closed_set() {
        let vo = synthesize("tone", &["good".to_string(), "warn".to_string()]);
        assert_eq!(vo.name, "Tone");
        assert!(vo.closed_set);
        assert_eq!(vo.attributes.len(), 1);
        assert_eq!(vo.attributes[0].name, "value");
        assert_eq!(vo.attributes[0].type_name, "String");
        assert_eq!(
            vo.members,
            vec![
                vec![("value".to_string(), "good".to_string())],
                vec![("value".to_string(), "warn".to_string())]
            ]
        );
    }

    #[test]
    fn pascal_cases_a_snake_field_name() {
        let vo = synthesize("identity_strategy", &["slug".to_string()]);
        assert_eq!(vo.name, "IdentityStrategy");
    }
}
