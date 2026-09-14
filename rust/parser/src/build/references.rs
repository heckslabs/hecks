//! Mirrors structural reference and relationship attribute minting.
//! `Reference<Target>` retains the target, `Attribute.list` retains
//! cardinality, and `Attribute.relationship` retains whether the author
//! said `has_many`, `has_one`, or `belongs_to`.

use crate::ir;

/// The ONE shape every `reference_to` attribute-mint reduces to:
/// `attribute(as || snake(target), Reference(target))` — bare, no
/// `_id` suffix (ADR 0025; the live parser never needs the
/// shadow-parsing fork `AttributeCollector#default_reference_name`
/// carries for frozen era text, since this parser only ever reads
/// current, live source). Shared verbatim by every builder that
/// includes `AttributeCollector` (`AggregateBuilder#reference_to`,
/// `CommandBuilder#cross_reference`, `QueryBuilder#reference_to`,
/// `PortOperationBuilder#reference_to`) — confirmed identical across
/// all four Ruby call sites.
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
