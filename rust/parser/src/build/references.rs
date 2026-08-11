//! Mirrors `reference_to`/`has_many`/`has_one`/`belongs_to` attribute
//! minting (`attribute_collector.rb` and its `AggregateBuilder`/
//! `EntityBuilder` callers). All four FILL the same field
//! (`reference_to` — see syntax.bluebook's own comment on why
//! `has_many`/`has_one`/`belongs_to` share it): each builds one
//! `Reference`-typed attribute. `has_many`'s target is the SINGULAR of
//! what was written and mints no `_id` suffix — a Ruby-builder naming
//! default this module has to reproduce exactly, not just the edge (which
//! ATTRIBUTE gets built) a projected parser needs.

use crate::ir;

/// The ONE shape every `reference_to` (and, on an aggregate,
/// `has_many`/`has_one`/`belongs_to` — not exercised by pizzas.bluebook,
/// left unbuilt here per this module's own header) attribute-mint reduces
/// to: `attribute(as || "#{snake(target)}_id", Reference(target))`.
/// Shared verbatim by every builder that includes `AttributeCollector`
/// (`AggregateBuilder#reference_to`, `CommandBuilder#cross_reference`,
/// `QueryBuilder#reference_to`, `PortOperationBuilder#reference_to`) —
/// confirmed identical across all four Ruby call sites.
pub fn reference_attribute(target: &str, as_name: Option<&str>, optional: bool) -> ir::Attribute {
    let target = crate::build::naming::demodulise(target);
    let name = as_name.map(|s| s.to_string()).unwrap_or_else(|| format!("{}_id", crate::build::naming::snake(&target)));
    ir::Attribute { name, type_name: format!("Reference<{target}>"), list: false, optional, ..Default::default() }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mints_an_explicitly_named_reference_attribute() {
        let attr = reference_attribute("Order", Some("name"), false);
        assert_eq!(attr.name, "name");
        assert_eq!(attr.type_name, "Reference<Order>");
    }

    #[test]
    fn defaults_the_name_from_the_target_when_as_is_absent() {
        let attr = reference_attribute("Customer", None, false);
        assert_eq!(attr.name, "customer_id");
        assert_eq!(attr.type_name, "Reference<Customer>");
    }
}
