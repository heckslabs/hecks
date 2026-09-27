//! Reference and relationship attribute minting.

use crate::ir;

/// Mints the attribute for a `reference_to`: `attribute(as || snake(target), Reference(target))`,
/// with no `_id` suffix.
pub fn reference_attribute(target: &str, as_name: Option<&str>, optional: bool) -> ir::Attribute {
    let target = crate::build::naming::demodulise(target);
    let name = as_name
        .map(|s| s.to_string())
        .unwrap_or_else(|| crate::build::naming::snake(&target));
    ir::Attribute {
        name,
        type_name: format!("Reference<{target}>"),
        list: false,
        optional,
        ..Default::default()
    }
}

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
