//! Integration tests for validator_warnings
//!
//! Builds Domain values directly to exercise:
//!   - aggregate_count_warning (>7 aggregates)
//!   - mixed_concerns_warning  (5+ aggregates, disconnected)
//!   - small connected domain  (no warnings)

use hecks_life::ir::{Aggregate, Command, Domain, Reference};
use hecks_life::validator_warnings::{aggregate_count_warning, mixed_concerns_warning};

fn agg(name: &str, refs: Vec<Reference>) -> Aggregate {
    Aggregate {
        name: name.to_string(),
        description: None,
        attributes: vec![],
        commands: vec![Command {
            name: format!("Touch{}", name),
            description: None,
            role: None,
            attributes: vec![],
            references: vec![],
            emits: None,
            givens: vec![],
            mutations: vec![],
        }],
        queries: vec![],
        value_objects: vec![],
        references: refs,
        lifecycle: None,
    }
}

fn reference_to(target: &str) -> Reference {
    Reference {
        name: target.to_lowercase(),
        target: target.to_string(),
        domain: None,
    }
}

fn empty_domain(name: &str, aggregates: Vec<Aggregate>) -> Domain {
    Domain {
        name: name.to_string(),
        category: None,
        vision: None,
        aggregates,
        policies: vec![],
        fixtures: vec![],
        entrypoint: None,
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
    assert!(msg.contains("splitting"), "got: {}", msg);
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
    assert!(mixed_concerns_warning(&domain).is_none());
}
