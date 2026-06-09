// rust/tests/validator_rules_test.rs
//
// Integration tests for the validator rules — moved out of
// rust/src/validator.rs as part of i51 Phase A commit 4
// (retirement). validator.rs is now purely generated from the
// validator_shape.fixtures via `bin/specialize validator`; tests
// live here so the circular dependency (specializer reading tests
// out of the file it's generating) is broken.
//
// When Phase B models test cases as fixtures (TestCase aggregate),
// these tests come back under the shape-driven pipeline.
//
// [antibody-exempt: rust/tests/validator_rules_test.rs — kernel-
//  surface test for the generated validator. Builds Domain literals
//  to exercise individual rules. Test-only kernel surface. Retires
//  with Phase B (TestCase aggregate models the cases as fixtures).]

use storehouse::ir::{Aggregate, Command, Domain, Policy};
use storehouse::parser;
use storehouse::validator::validate;
use storehouse::validator_corpus::unknown_aggregate_errors;

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
fn forbids_cross_aggregate_read_in_given() {
    let domain = parser::parse(r#"Hecks.bluebook "X" do
  aggregate "Foo" do
    command "Touch" do
      role "Self"
      given("forbidden") { Bar(name).status == "ok" }
    end
  end
end"#);
    let errors = validate(&domain);
    assert!(
        errors.iter().any(|e| e.contains("cross-aggregate read") && e.contains("Bar(name)")),
        "a given with a cross-aggregate read must be rejected, got: {:?}",
        errors
    );
}

#[test]
fn allows_a_given_that_reads_only_local_state() {
    let domain = parser::parse(r#"Hecks.bluebook "X" do
  aggregate "Foo" do
    command "Touch" do
      role "Self"
      given("local") { sprint_active == true }
    end
  end
end"#);
    assert!(
        !validate(&domain).iter().any(|e| e.contains("cross-aggregate read")),
        "a given reading only its own state must pass"
    );
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
                    emits_identified_by: None,
                    givens: vec![],
                    mutations: vec![],
                }],
                value_objects: vec![], entities: vec![], context: None, category: None,
                references: vec![],
                lifecycle: None, invariants: vec![],
                identified_by: None,
                views: vec![],
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
                    emits_identified_by: None,
                    givens: vec![],
                    mutations: vec![],
                }],
                value_objects: vec![], entities: vec![], context: None, category: None,
                references: vec![],
                lifecycle: None, invariants: vec![],
                identified_by: None,
                views: vec![],
                queries: vec![],
            },
        ],
        process_managers: vec![],
        policies: vec![],
        fixtures: vec![],
        entrypoint: None,
        sections: vec![],
        cadences: vec![],
        block_grammars: vec![],
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
            value_objects: vec![], entities: vec![], context: None, category: None,
            references: vec![],
            lifecycle: None, invariants: vec![],
            identified_by: None,
            views: vec![],
            queries: vec![],
        }],
        process_managers: vec![],
        policies: vec![],
        fixtures: vec![],
        entrypoint: None,
        sections: vec![],
        cadences: vec![],
        block_grammars: vec![],
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
                emits_identified_by: None,
                givens: vec![],
                mutations: vec![],
            }],
            value_objects: vec![], entities: vec![], context: None, category: None,
            references: vec![],
            lifecycle: None, invariants: vec![],
            identified_by: None,
            views: vec![],
            queries: vec![],
        }],
        process_managers: vec![],
        policies: vec![],
        fixtures: vec![],
        entrypoint: None,
        sections: vec![],
        cadences: vec![],
        block_grammars: vec![],
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
    // valid_references retired from the per-file `validate` (it false-positived
    // on legitimate cross-bluebook belongs_to). The dangling-reference check
    // now lives in the corpus pass : unknown_aggregate_errors(domain, corpus).
    // A self-contained domain is its own corpus, so a target absent from it is
    // still flagged. validate() alone no longer reports it.
    assert!(
        !validate(&domain)
            .iter()
            .any(|e| e.contains("unknown aggregate")),
        "per-file validate must no longer run the reference check"
    );
    let errors = unknown_aggregate_errors(&domain, &domain);
    assert!(errors
        .iter()
        .any(|e| e.contains("unknown aggregate: Widget")));
}

#[test]
fn duplicate_reference_aliases_errors() {
    // Two reference_to pointing at the same target with the same alias
    // should fail the distinct_reference_aliases rule. With `as:` aliases
    // giving each a distinct name, the check passes.
    let duped = parser::parse(r#"Hecks.bluebook "T" do
  aggregate "Account" do
    command "Create" do
      role "Owner"
    end
  end
  aggregate "Transfer" do
    reference_to Account
    reference_to Account
    command "Initiate" do
      role "Customer"
    end
  end
end"#);
    let errors = validate(&duped);
    assert!(
        errors.iter().any(|e| e.contains("duplicate alias")),
        "expected duplicate-alias error, got: {:?}",
        errors
    );

    let aliased = parser::parse(r#"Hecks.bluebook "T" do
  aggregate "Account" do
    command "Create" do
      role "Owner"
    end
  end
  aggregate "Transfer" do
    reference_to Account, as: :source
    reference_to Account, as: :destination
    command "Initiate" do
      role "Customer"
    end
  end
end"#);
    let errors = validate(&aliased);
    assert!(
        !errors.iter().any(|e| e.contains("duplicate alias")),
        "with distinct aliases should pass; got: {:?}",
        errors
    );
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
                emits_identified_by: None,
                givens: vec![],
                mutations: vec![],
            }],
            value_objects: vec![], entities: vec![], context: None, category: None,
            references: vec![],
            lifecycle: None, invariants: vec![],
            identified_by: None,
            views: vec![],
            queries: vec![],
        }],
        process_managers: vec![],
        policies: vec![Policy {
            name: "NotifyOnOrder".into(),
            on_event: "OrderPlaced".into(),
            trigger_command: "GhostCommand".into(),
            target_domain: None,
            with: vec![],
        }],
        fixtures: vec![],
        entrypoint: None,
        sections: vec![],
        cadences: vec![],
        block_grammars: vec![],
    };
    let errors = validate(&domain);
    assert!(errors
        .iter()
        .any(|e| e.contains("triggers unknown command")));
}
