//! `has_many`, `has_one`, `belongs_to` — relationship vocabulary this parser
//! already read (cherry-picked from Hecks) while Ruby's DSL had not yet
//! landed it, so a bluebook using one parsed on ONE SIDE ONLY. Ruby has it
//! now (AggregateBuilder#has_many/has_one/belongs_to), and this holds Rust's
//! reading of the same words to the SHAPE Ruby produces : one
//! `Reference<Target>` attribute per word, named with no `_id` mint.
//!
//! `absorb_held` (has_one/belongs_to's shared body) used to ALSO push a
//! second, bare-typed attribute of the same name onto a separate vector, and
//! nothing ever caught it — the guard meant to prevent the duplicate could
//! never see the attribute the same call had just pushed elsewhere. These
//! tests are what would have caught it.

use storehouse::parser;

fn parse_one_aggregate(source: &str) -> storehouse::ir::Aggregate {
    let domain = parser::parse(source);
    domain
        .aggregates
        .into_iter()
        .find(|a| a.name != "Target")
        .expect("the aggregate under test")
}

#[test]
fn has_one_builds_a_single_reference_named_for_the_target() {
    let agg = parse_one_aggregate(
        "Hecks.bluebook \"Owning\" do\n  \
           aggregate \"Target\" do\n    identified_by { id.value }\n  end\n  \
           aggregate \"Account\" do\n    identified_by { id.value }\n    has_one Target\n  end\n\
         end\n",
    );

    let matches: Vec<_> = agg.attributes.iter().filter(|a| a.name == "target").collect();
    assert_eq!(matches.len(), 1, "has_one must build exactly one attribute, found {matches:?}");
    assert_eq!(matches[0].r#type, "Reference<Target>");
    assert!(!matches[0].list);
}

#[test]
fn belongs_to_reads_identically_to_has_one() {
    let agg = parse_one_aggregate(
        "Hecks.bluebook \"Dependent\" do\n  \
           aggregate \"Target\" do\n    identified_by { id.value }\n  end\n  \
           aggregate \"Player\" do\n    identified_by { id.value }\n    belongs_to Target\n  end\n\
         end\n",
    );

    let matches: Vec<_> = agg.attributes.iter().filter(|a| a.name == "target").collect();
    assert_eq!(matches.len(), 1, "belongs_to must build exactly one attribute, found {matches:?}");
    assert_eq!(matches[0].r#type, "Reference<Target>");
}

#[test]
fn has_many_singularizes_the_target_and_names_the_attribute_for_the_plural_written() {
    let agg = parse_one_aggregate(
        "Hecks.bluebook \"Holding\" do\n  \
           aggregate \"Target\" do\n    identified_by { id.value }\n  end\n  \
           aggregate \"Ledger\" do\n    identified_by { id.value }\n    has_many Targets\n  end\n\
         end\n",
    );

    let matches: Vec<_> = agg.attributes.iter().filter(|a| a.name == "targets").collect();
    assert_eq!(matches.len(), 1, "has_many must build exactly one attribute, found {matches:?}");
    assert_eq!(matches[0].r#type, "Reference<Target>");
    assert!(!matches[0].list, "has_many matches Rust's existing shape — a single reference, not a list");
}

/// The hand-probe that found the SECOND bug in this arc. `parse_aggregate`
/// used to collect `reference_to`/`has_many`/`has_one`/`belongs_to` into a
/// SEPARATE vector, prepended at the end, on the claim that "the IR has
/// always listed every reference before every declared field". Every real
/// aggregate in the corpus happens to write its references immediately after
/// `identified_by`, before any plain `attribute` — so declaration order and
/// "references first" were the same order every time, and nothing told them
/// apart. This aggregate declares `id` FIRST, which is normal and Ruby
/// preserves it: `attribute :id` then `has_many` then `attribute :label`
/// comes back `[id, targets, label]`, not references-first.
#[test]
fn attributes_and_relationships_keep_true_declaration_order_when_interleaved() {
    let agg = parse_one_aggregate(
        "Hecks.bluebook \"Ordered\" do\n  \
           aggregate \"Target\" do\n    identified_by { id.value }\n  end\n  \
           aggregate \"Ledger\" do\n    identified_by { id.value }\n    \
             attribute :id, LedgerId\n    \
             has_many Targets\n    \
             attribute :label, Label\n  \
           end\n\
         end\n",
    );

    let names: Vec<&str> = agg.attributes.iter().map(|a| a.name.as_str()).collect();
    assert_eq!(names, vec!["id", "targets", "label"]);
}

#[test]
fn all_three_take_as_to_override_the_default_name() {
    let agg = parse_one_aggregate(
        "Hecks.bluebook \"Aliased\" do\n  \
           aggregate \"Target\" do\n    identified_by { id.value }\n  end\n  \
           aggregate \"Shipment\" do\n    identified_by { id.value }\n    \
             has_many Targets, as: :origins\n    \
             has_one Target, as: :dispatch_point\n    \
             belongs_to Target, as: :destination\n  \
           end\n\
         end\n",
    );

    for name in ["origins", "dispatch_point", "destination"] {
        let matches: Vec<_> = agg.attributes.iter().filter(|a| a.name == name).collect();
        assert_eq!(matches.len(), 1, "{name} must be exactly one attribute, found {matches:?}");
        assert_eq!(matches[0].r#type, "Reference<Target>");
    }
}
