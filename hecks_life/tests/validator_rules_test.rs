// hecks_life/tests/validator_rules_test.rs
//
// Integration tests for the validator rules — moved out of
// hecks_life/src/validator.rs as part of i51 Phase A commit 4
// (retirement). validator.rs is now purely generated from the
// validator_shape.fixtures via bin/specialize-validator; tests
// live here so the circular dependency (specializer reading tests
// out of the file it's generating) is broken.
//
// When Phase B models test cases as fixtures (TestCase aggregate),
// these tests come back under the shape-driven pipeline.

use hecks_life::ir::{Aggregate, Command, Domain, Policy};
use hecks_life::parser;
use hecks_life::validator::validate;

#[test]
fn valid_domain_passes() {
    let domain = parser::parse(r#"Hecks.bluebook "T" do
  aggregate "Pizza" do
    description "A pizza"
    command "CreatePizza" do
      role "Chef"
    end
  end
end"#);
    assert!(validate(&domain).is_empty());
}

#[test]
fn duplicate_aggregate_names() {
    let domain = Domain {
        name: "T".into(),
        category: None,
        vision: None,
        aggregates: vec![
            Aggregate {
                name: "Pizza".into(),
                description: None,
                attributes: vec![],
                commands: vec![Command {
                    name: "CreatePizza".into(),
                    description: None,
                    role: None,
                    attributes: vec![],
                    references: vec![],
                    emits: None,
                    givens: vec![],
                    mutations: vec![],
                }],
                value_objects: vec![],
                references: vec![],
                lifecycle: None,
                queries: vec![],
            },
            Aggregate {
                name: "Pizza".into(),
                description: None,
                attributes: vec![],
                commands: vec![Command {
                    name: "UpdatePizza".into(),
                    description: None,
                    role: None,
                    attributes: vec![],
                    references: vec![],
                    emits: None,
                    givens: vec![],
                    mutations: vec![],
                }],
                value_objects: vec![],
                references: vec![],
                lifecycle: None,
                queries: vec![],
            },
        ],
        policies: vec![],
        fixtures: vec![],
        entrypoint: None,
    };
    let errors = validate(&domain);
    assert!(errors.iter().any(|e| e.contains("Duplicate aggregate")));
}

#[test]
fn aggregate_without_commands() {
    let domain = Domain {
        name: "T".into(),
        category: None,
        vision: None,
        aggregates: vec![Aggregate {
            name: "Orphan".into(),
            description: None,
            attributes: vec![],
            commands: vec![],
            value_objects: vec![],
            references: vec![],
            lifecycle: None,
            queries: vec![],
        }],
        policies: vec![],
        fixtures: vec![],
        entrypoint: None,
    };
    let errors = validate(&domain);
    assert!(errors.iter().any(|e| e.contains("has no commands")));
}

#[test]
fn bad_command_naming() {
    let domain = Domain {
        name: "T".into(),
        category: None,
        vision: None,
        aggregates: vec![Aggregate {
            name: "Pizza".into(),
            description: None,
            attributes: vec![],
            // First-word noun: validator's noun-suffix detector flags
            // the leading word ("Configuration"), not the trailing one.
            commands: vec![Command {
                name: "ConfigurationPizza".into(),
                description: None,
                role: None,
                attributes: vec![],
                references: vec![],
                emits: None,
                givens: vec![],
                mutations: vec![],
            }],
            value_objects: vec![],
            references: vec![],
            lifecycle: None,
            queries: vec![],
        }],
        policies: vec![],
        fixtures: vec![],
        entrypoint: None,
    };
    let errors = validate(&domain);
    assert!(errors
        .iter()
        .any(|e| e.contains("commands should start with a verb")));
}

#[test]
fn unknown_reference() {
    let domain = parser::parse(r#"Hecks.bluebook "T" do
  aggregate "Order" do
    description "An order"
    reference_to Widget
    command "PlaceOrder" do
      role "Customer"
    end
  end
end"#);
    let errors = validate(&domain);
    assert!(errors
        .iter()
        .any(|e| e.contains("unknown aggregate: Widget")));
}

#[test]
fn unknown_policy_trigger() {
    let domain = Domain {
        name: "T".into(),
        category: None,
        vision: None,
        aggregates: vec![Aggregate {
            name: "Order".into(),
            description: None,
            attributes: vec![],
            commands: vec![Command {
                name: "PlaceOrder".into(),
                description: None,
                role: None,
                attributes: vec![],
                references: vec![],
                emits: Some("OrderPlaced".into()),
                givens: vec![],
                mutations: vec![],
            }],
            value_objects: vec![],
            references: vec![],
            lifecycle: None,
            queries: vec![],
        }],
        policies: vec![Policy {
            name: "NotifyOnOrder".into(),
            on_event: "OrderPlaced".into(),
            trigger_command: "GhostCommand".into(),
            target_domain: None,
        }],
        fixtures: vec![],
        entrypoint: None,
    };
    let errors = validate(&domain);
    assert!(errors
        .iter()
        .any(|e| e.contains("triggers unknown command")));
}
