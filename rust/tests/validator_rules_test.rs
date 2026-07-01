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
use storehouse::validator_corpus::{ambiguous_cross_reference_errors, unknown_aggregate_errors};
use storehouse::validator_inside_refs::dangling_inside_reference_errors;

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
                factories: vec![],
                commands: vec![Command {
                    name: "CreatePizza".into(),
                    description: None,
                    role: None,
                    attributes: vec![],
                    references: vec![],
                    emits: None,
                    emits_identified_by: None,
                    givens: vec![],
                    mutations: vec![], redirects_native: vec![],
                }],
                value_objects: vec![], entities: vec![], context: None, category: None, realm_path: None,
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
                factories: vec![],
                commands: vec![Command {
                    name: "UpdatePizza".into(),
                    description: None,
                    role: None,
                    attributes: vec![],
                    references: vec![],
                    emits: None,
                    emits_identified_by: None,
                    givens: vec![],
                    mutations: vec![], redirects_native: vec![],
                }],
                value_objects: vec![], entities: vec![], context: None, category: None, realm_path: None,
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
            factories: vec![],
            commands: vec![],
            value_objects: vec![], entities: vec![], context: None, category: None, realm_path: None,
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
            factories: vec![],
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
                mutations: vec![], redirects_native: vec![],
            }],
            value_objects: vec![], entities: vec![], context: None, category: None, realm_path: None,
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
            factories: vec![],
            commands: vec![Command {
                name: "PlaceOrder".into(),
                description: None,
                role: None,
                attributes: vec![],
                references: vec![],
                emits: Some("OrderPlaced".into()),
                emits_identified_by: None,
                givens: vec![],
                mutations: vec![], redirects_native: vec![],
            }],
            value_objects: vec![], entities: vec![], context: None, category: None, realm_path: None,
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
            wheres: vec![],
            for_each: None,
            extra_dispatches: vec![],
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

// ── ambiguous_cross_reference_errors (the no-silent-guess rule) ──
// Build a corpus where `Worker` is declared in two contexts (Conductor +
// SeedingWorker), plus a `Thing` whose context + cross-ref line vary per
// test. Mirrors the real corpus shape that motivated the rule.
fn corpus_with_two_workers(thing_context: &str, thing_ref_line: &str) -> Domain {
    let mut corpus = parser::parse(&format!(
        "Hecks.bluebook \"Probe\" do\n  aggregate \"Thing\" do\n    {}\n    command \"Make\" do role \"T\" end\n  end\nend",
        thing_ref_line
    ));
    corpus.aggregates[0].context = Some(thing_context.to_string());
    for ctx in ["Conductor", "SeedingWorker"] {
        let mut w = parser::parse(
            "Hecks.bluebook \"W\" do\n  aggregate \"Worker\" do\n    command \"Reg\" do role \"T\" end\n  end\nend",
        )
        .aggregates
        .remove(0);
        w.context = Some(ctx.to_string());
        corpus.aggregates.push(w);
    }
    corpus
}

#[test]
fn flags_unqualified_cross_ref_ambiguous_across_contexts() {
    // Thing lives in neither Worker context -> no same-context candidate.
    let corpus = corpus_with_two_workers("ThingCtx", "has_one Worker");
    let errors = ambiguous_cross_reference_errors(&corpus, &corpus);
    assert!(
        errors.iter().any(|e| e.contains("Thing has_one Worker is ambiguous")
            && e.contains("Conductor")
            && e.contains("SeedingWorker")),
        "ambiguous unqualified cross ref must error, got: {:?}",
        errors
    );
}

#[test]
fn same_context_candidate_resolves_unqualified_cross_ref() {
    // Thing shares the Conductor context with one Worker -> resolves, as
    // the runtime resolves (same-context first). No error.
    let corpus = corpus_with_two_workers("Conductor", "has_one Worker");
    let errors = ambiguous_cross_reference_errors(&corpus, &corpus);
    assert!(
        !errors.iter().any(|e| e.contains("ambiguous")),
        "a same-context candidate must resolve the ref, got: {:?}",
        errors
    );
}

#[test]
fn qualified_cross_ref_is_not_flagged() {
    // A qualified target (Conductor::Worker sets reference.domain) names
    // its context, so the rule skips it even with no same-context match.
    let corpus = corpus_with_two_workers("ThingCtx", "has_one Conductor::Worker");
    let errors = ambiguous_cross_reference_errors(&corpus, &corpus);
    assert!(
        !errors.iter().any(|e| e.contains("ambiguous")),
        "a qualified cross ref must not be flagged, got: {:?}",
        errors
    );
}

// ── dangling_inside_reference_errors (per-file inside-boundary refs) ──
// `reference_to X` is an INSIDE-boundary ref : its resolution universe is the
// single file, so a dangling target is provable with no corpus. These lock the
// bare-`validate` hole a newcomer hits first (DX perfection game, Tier 0 #4).

#[test]
fn inside_ref_dangling_is_flagged() {
// reference_to a nonexistent aggregate, declared at aggregate level.
let domain = parser::parse(r#"Hecks.bluebook "T" do
aggregate "Order" do
description "An order"
reference_to Widget
command "PlaceOrder" do
  role "Customer"
end
end
end"#);
let errors = dangling_inside_reference_errors(&domain);
assert!(
    errors.iter().any(|e| e.contains("unknown aggregate: Widget")),
    "a dangling reference_to must be flagged per-file, got: {:?}",
    errors
);
}

#[test]
fn inside_ref_dangling_in_command_is_flagged() {
// reference_to a nonexistent aggregate, declared inside a command : the
// "Command <name>" message branch.
let domain = parser::parse(r#"Hecks.bluebook "T" do
aggregate "Order" do
description "An order"
command "Cancel" do
  role "Customer"
  reference_to Widget
end
end
end"#);
let errors = dangling_inside_reference_errors(&domain);
assert!(
    errors.iter().any(|e| e.contains("Command Cancel references unknown aggregate: Widget")),
    "a dangling command-level reference_to must be flagged, got: {:?}",
    errors
);
}

#[test]
fn inside_ref_to_sibling_resolves() {
// reference_to a same-file sibling aggregate resolves — no error.
let domain = parser::parse(r#"Hecks.bluebook "T" do
aggregate "Pizza" do
description "A pizza"
command "CreatePizza" do
  role "Chef"
end
end
aggregate "Order" do
description "An order"
reference_to Pizza
command "PlaceOrder" do
  role "Customer"
end
end
end"#);
assert!(
    dangling_inside_reference_errors(&domain).is_empty(),
    "reference_to a declared sibling must resolve"
);
}

#[test]
fn inside_ref_self_resolves() {
// The self-ref transition-command form (reference_to the aggregate itself)
// resolves against the same-file aggregate name.
let domain = parser::parse(r#"Hecks.bluebook "T" do
aggregate "Order" do
description "An order"
identified_by :name
command "Cancel" do
  role "Customer"
  reference_to Order
end
end
end"#);
assert!(
    dangling_inside_reference_errors(&domain).is_empty(),
    "reference_to the aggregate itself must resolve"
);
}

#[test]
fn cross_kind_ref_is_not_checked_per_file() {
// belongs_to / has_one / has_many may target a sibling BLUEBOOK, so the
// per-file inside check must ignore them — only the corpus pass owns them.
// Story is undeclared here yet must NOT be flagged by this rule.
let domain = parser::parse(r#"Hecks.bluebook "T" do
aggregate "Lease" do
description "A lease"
belongs_to Story
command "Grant" do
  role "System"
end
end
end"#);
assert!(
    dangling_inside_reference_errors(&domain).is_empty(),
    "a cross-kind belongs_to (potentially cross-bluebook) must NOT be flagged per-file"
);
}
