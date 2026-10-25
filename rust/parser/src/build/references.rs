//! Reference and relationship attribute minting.

use crate::ir;

/// Mints the attribute for a `reference_to`: `attribute(as || snake(target), Reference(target))`,
/// with no `_id` suffix.
pub fn reference_attribute(target: &str, as_name: Option<&str>, optional: bool) -> ir::Attribute {
    let target = crate::build::naming::demodulise(target);
    let name = as_name.map_or_else(
        || crate::build::naming::snake(&target),
        std::string::ToString::to_string,
    );
    ir::Attribute {
        name,
        type_name: format!("Reference<{target}>"),
        list: false,
        optional,
        ..Default::default()
    }
}

/// The shapes `reference_to one_of(A, B), as: :subject` mints (ADR 0127), mirroring
/// `AggregateBuilder::OneOfReference`: the `one_of` attribute, the closed set of the variants'
/// names (`SubjectType`) and the tagged value object (`Subject`, a `type` and an `id`).
pub struct OneOfReference {
    pub attribute: ir::Attribute,
    pub type_set: ir::ValueObject,
    pub tagged: ir::ValueObject,
}

/// Mints a tagged reference's attribute and shapes; `aggregate` qualifies the `admits:` name.
pub fn one_of_reference(
    aggregate: &str,
    variants: &[String],
    as_name: &str,
    optional: bool,
) -> OneOfReference {
    let tagged_name = crate::build::naming::pascal(as_name);
    let set_name = format!("{tagged_name}Type");
    let mut type_set = crate::build::closed_sets::synthesize(&set_name, variants);
    type_set.name.clone_from(&set_name);
    let string_field = |name: &str, admits: Option<String>| ir::Attribute {
        name: name.to_string(),
        type_name: "String".to_string(),
        admits,
        ..Default::default()
    };
    let tagged = ir::ValueObject {
        name: tagged_name.clone(),
        attributes: vec![
            string_field("type", Some(format!("{aggregate}::{set_name}"))),
            string_field("id", None),
        ],
        invariants: Vec::new(),
        closed_set: false,
        members: Vec::new(),
    };
    let attribute = ir::Attribute {
        name: as_name.to_string(),
        type_name: tagged_name,
        optional,
        relationship: Some("one_of".to_string()),
        ..Default::default()
    };
    OneOfReference {
        attribute,
        type_set,
        tagged,
    }
}

/// Mints a relationship attribute (`reference_to`, `has_one`, `belongs_to`, `has_many`), recording
/// the word that minted it.
pub fn relationship_attribute(
    target: &str,
    kind: &str,
    as_name: Option<&str>,
    optional: bool,
    list: bool,
) -> ir::Attribute {
    let mut attribute = reference_attribute(target, as_name, optional);
    attribute.list = list;
    attribute.relationship = Some(kind.to_string());
    attribute
}
