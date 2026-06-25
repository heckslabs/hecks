//! Integration tests for validator_warnings
//!
//! Builds Domain values directly to exercise:
//!   - aggregate_count_warning      (>7 aggregates — first-tier notice)
//!   - multi_domain_split_warning   (>11 aggregates — second-tier warn)
//!   - mixed_concerns_warning       (5+ aggregates, disconnected)
//!   - small connected domain       (no warnings)
//!
//! [antibody-exempt: rust/tests/validator_warnings_test.rs — kernel-
//!  surface test for validator_warnings logic, builds Domain literals
//!  directly to exercise the warning rules. Test-only kernel surface.
//!  Retires when validators are bluebook-driven via meta-shape (the
//!  same path that retired meta_diagnostic_validator).]

use storehouse::ir::{Aggregate, Command, Domain, Reference};
use storehouse::validator_warnings::{
    aggregate_count_warning, mixed_concerns_warning, multi_domain_split_warning,
};

fn agg(name: &str, refs: Vec<Reference>) -> Aggregate {
    Aggregate {
        name: name.to_string(),
        description: None,
        attributes: vec![],
        factories: vec![],
        commands: vec![Command {
            name: format!("Touch{}", name),
            description: None,
            role: None,
            attributes: vec![],
            references: vec![],
            emits: None,
            emits_identified_by: None,
            givens: vec![],
            mutations: vec![],
        }],
        queries: vec![],
        value_objects: vec![], entities: vec![], context: None, category: None, realm_path: None,
        references: refs,
        lifecycle: None, invariants: vec![],
        identified_by: None,
        views: vec![],
    }
}

fn reference_to(target: &str) -> Reference {
    // Reference gained `cardinality` and `kind` via the relationship-DSL
    // shape sweep ; route construction through Reference::single
    // (LegacyReferenceTo + single cardinality defaults) so this helper
    // stays semantically equivalent as the struct evolves.
    Reference::single(target.to_lowercase(), target.to_string(), None)
}

fn empty_domain(name: &str, aggregates: Vec<Aggregate>) -> Domain {
    Domain {
        name: name.to_string(),
        category: None,
        vision: None,
        aggregates,
        process_managers: vec![],
        policies: vec![],
        fixtures: vec![],
        entrypoint: None,
        sections: vec![],
        cadences: vec![],
        block_grammars: vec![],
    }
}

#[test]
fn warns_when_domain_has_more_than_seven_aggregates() {
    // 8 aggregates, fully connected in a chain so mixed_concerns stays quiet
    let aggs: Vec<Aggregate> = (0..8)
        .map(|i| {
            let name = format!("A{}", i);
            let refs = if i + 1 < 8 {
                vec![reference_to(&format!("A{}", i + 1))]
            } else {
                vec![]
            };
            agg(&name, refs)
        })
        .collect();
    let domain = empty_domain("BigDomain", aggs);

    let msg = aggregate_count_warning(&domain)
        .expect("expected aggregate_count_warning for 8 aggregates");
    assert!(msg.contains("BigDomain"), "got: {}", msg);
    assert!(msg.contains("8"), "got: {}", msg);
    assert!(msg.contains("cohesion"), "got: {}", msg);
    // Second-tier warning should NOT fire at 8 aggregates (threshold is 11)
    assert!(multi_domain_split_warning(&domain).is_none());
}

#[test]
fn warns_with_split_severity_when_domain_has_more_than_eleven_aggregates() {
    // 12 aggregates, fully connected — first-tier still fires AND
    // second-tier (multi_domain_split_warning) fires too.
    let aggs: Vec<Aggregate> = (0..12)
        .map(|i| {
            let name = format!("A{}", i);
            let refs = if i + 1 < 12 {
                vec![reference_to(&format!("A{}", i + 1))]
            } else {
                vec![]
            };
            agg(&name, refs)
        })
        .collect();
    let domain = empty_domain("HugeDomain", aggs);

    let first_tier = aggregate_count_warning(&domain)
        .expect("expected aggregate_count_warning at 12 aggregates (first tier)");
    assert!(first_tier.contains("12"), "got: {}", first_tier);

    let second_tier = multi_domain_split_warning(&domain)
        .expect("expected multi_domain_split_warning at 12 aggregates (second tier)");
    assert!(second_tier.contains("HugeDomain"), "got: {}", second_tier);
    assert!(second_tier.contains("12"), "got: {}", second_tier);
    assert!(
        second_tier.contains("split"),
        "got: {}",
        second_tier
    );
}

#[test]
fn warns_when_aggregates_split_into_disconnected_clusters() {
    // Cluster 1: A - B - C (via reference_to)
    // Cluster 2: X - Y     (via reference_to)
    let aggregates = vec![
        agg("A", vec![reference_to("B")]),
        agg("B", vec![reference_to("C")]),
        agg("C", vec![]),
        agg("X", vec![reference_to("Y")]),
        agg("Y", vec![]),
    ];
    let domain = empty_domain("Split", aggregates);

    // aggregate_count_warning should NOT fire (only 5 aggregates)
    assert!(aggregate_count_warning(&domain).is_none());

    let msg = mixed_concerns_warning(&domain)
        .expect("expected mixed_concerns_warning for disconnected clusters");
    assert!(msg.contains("Split"), "got: {}", msg);
    assert!(msg.contains("disconnected"), "got: {}", msg);
    // Both cluster members should appear somewhere in the rendered list
    assert!(msg.contains('A') && msg.contains('X'), "got: {}", msg);
}

#[test]
fn no_warnings_on_small_connected_domain() {
    // 3 aggregates, fully connected — below both thresholds
    let aggregates = vec![
        agg("A", vec![reference_to("B")]),
        agg("B", vec![reference_to("C")]),
        agg("C", vec![]),
    ];
    let domain = empty_domain("Tiny", aggregates);

    assert!(aggregate_count_warning(&domain).is_none());
    assert!(multi_domain_split_warning(&domain).is_none());
    assert!(mixed_concerns_warning(&domain).is_none());
}

fn ref_attr(name: &str, ty: &str) -> storehouse::ir::Attribute {
    storehouse::ir::Attribute {
        name: name.into(), attr_type: ty.into(), default: None, list: false, required: false,
    }
}

#[test]
fn mixed_concerns_counts_stored_ref_vo_attributes_as_edges() {
    // The "refs must be stored VOs" lesson : cross-aggregate coupling rides a
    // stored `<Target>Ref` VO attribute, NOT a reference_to (only a stored VO
    // rides emitted events + answers where-queries). The cohesion graph must
    // count those edges, else a domain that follows the lesson trips a FALSE
    // disconnected-clusters warning. Submission couples to Decision
    // (DecisionRef) and Player (PlayerRef) via STORED attrs only — no
    // reference_to — and Player has no ref at all. With *Ref edges counted, the
    // whole domain is ONE component and mixed_concerns stays quiet.
    let mut submission = agg("Submission", vec![]);
    submission.attributes = vec![ref_attr("decision", "DecisionRef"), ref_attr("player", "PlayerRef")];
    let aggregates = vec![
        agg("Decision", vec![]),
        agg("Option", vec![reference_to("Decision")]),
        agg("Bracket", vec![reference_to("Decision")]),
        agg("Player", vec![]),
        submission,
    ];
    let domain = empty_domain("Deciderate", aggregates);
    assert!(
        mixed_concerns_warning(&domain).is_none(),
        "stored *Ref VO attrs must connect the graph (no false cluster warning); got: {:?}",
        mixed_concerns_warning(&domain)
    );
}

#[test]
fn mixed_concerns_ignores_ref_suffix_that_is_not_an_aggregate() {
    // A `WinnerRef` / `PaymentRef` whose stem is NOT a sibling aggregate must
    // NOT manufacture an edge — only real aggregate coupling counts. Two
    // genuinely disconnected clusters (+ a singleton) stay disconnected.
    let mut a = agg("A", vec![reference_to("B")]);
    a.attributes = vec![ref_attr("winner", "WinnerRef")]; // stem "Winner" is not an aggregate
    let aggregates = vec![
        a,
        agg("B", vec![]),
        agg("X", vec![reference_to("Y")]),
        agg("Y", vec![]),
        agg("Z", vec![]),
    ];
    let domain = empty_domain("Split", aggregates);
    let msg = mixed_concerns_warning(&domain)
        .expect("WinnerRef stem is not an aggregate, so clusters stay split");
    assert!(msg.contains("disconnected"), "got: {}", msg);
}
