//! Domain validator — checks a parsed domain for DDD consistency
//!
//! Ports the Ruby Hecks::Validator rules to Rust. Each rule inspects
//! the Domain IR and returns error strings. An empty vec means valid.
//!
//! Usage:
//!   let errors = validator::validate(&domain);
//!   if errors.is_empty() { println!("VALID"); }

use crate::ir::Domain;
use std::collections::HashSet;

/// Run all validation rules and return collected errors.
pub fn validate(domain: &Domain) -> Vec<String> {
    let mut errors = vec![];
    errors.extend(unique_aggregate_names(domain));
    errors.extend(aggregates_have_commands(domain));
    errors.extend(command_naming(domain));
    errors.extend(valid_references(domain));
    errors.extend(valid_policy_triggers(domain));
    errors.extend(no_duplicate_commands(domain));
    errors
}

/// No two aggregates may share the same name.
fn unique_aggregate_names(domain: &Domain) -> Vec<String> {
    let mut seen = HashSet::new();
    let mut errors = vec![];
    for agg in &domain.aggregates {
        if !seen.insert(&agg.name) {
            errors.push(format!("Duplicate aggregate name: {}", agg.name));
        }
    }
    errors
}

/// Every aggregate must have at least one command.
fn aggregates_have_commands(domain: &Domain) -> Vec<String> {
    domain
        .aggregates
        .iter()
        .filter(|a| a.commands.is_empty())
        .map(|a| format!("{} has no commands", a.name))
        .collect()
}

/// Verb list compiled from Ruby + WordNet (source of truth: verbs.txt)
const VERBS_RAW: &str = include_str!("../../verbs.txt");

fn load_verbs() -> Vec<&'static str> {
    VERBS_RAW.lines().filter(|l| !l.is_empty()).collect()
}

/// Command names must start with a verb.
fn command_naming(domain: &Domain) -> Vec<String> {
    let verbs = load_verbs();
    let mut errors = vec![];
    for agg in &domain.aggregates {
        for cmd in &agg.commands {
            let starts_with_verb = verbs.iter().any(|v| cmd.name.starts_with(v));
            if !starts_with_verb {
                errors.push(format!(
                    "Command {} in {} doesn't start with a verb",
                    cmd.name, agg.name
                ));
            }
        }
    }
    errors
}

/// References must target existing aggregate roots.
fn valid_references(domain: &Domain) -> Vec<String> {
    let agg_names: HashSet<&str> = domain
        .aggregates
        .iter()
        .map(|a| a.name.as_str())
        .collect();

    let mut errors = vec![];
    for agg in &domain.aggregates {
        for reference in &agg.references {
            if reference.domain.is_some() {
                continue; // cross-domain refs validated elsewhere
            }
            if !agg_names.contains(reference.target.as_str()) {
                errors.push(format!(
                    "{} references unknown aggregate: {}",
                    agg.name, reference.target
                ));
            }
        }
        for cmd in &agg.commands {
            for reference in &cmd.references {
                if reference.domain.is_some() {
                    continue;
                }
                if !agg_names.contains(reference.target.as_str()) {
                    errors.push(format!(
                        "Command {} references unknown aggregate: {}",
                        cmd.name, reference.target
                    ));
                }
            }
        }
    }
    errors
}

/// Policy triggers must name existing commands.
fn valid_policy_triggers(domain: &Domain) -> Vec<String> {
    let all_commands: HashSet<&str> = domain
        .aggregates
        .iter()
        .flat_map(|a| a.commands.iter().map(|c| c.name.as_str()))
        .collect();

    domain
        .policies
        .iter()
        .filter(|p| p.target_domain.is_none()) // skip cross-domain
        .filter(|p| !all_commands.contains(p.trigger_command.as_str()))
        .map(|p| {
            format!(
                "Policy {} triggers unknown command: {}",
                p.name, p.trigger_command
            )
        })
        .collect()
}

/// No two commands across all aggregates should share the same name.
fn no_duplicate_commands(domain: &Domain) -> Vec<String> {
    let mut seen = HashSet::new();
    let mut errors = vec![];
    for agg in &domain.aggregates {
        for cmd in &agg.commands {
            if !seen.insert(&cmd.name) {
                errors.push(format!(
                    "Duplicate command name: {} (in {})",
                    cmd.name, agg.name
                ));
            }
        }
    }
    errors
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::parser;

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
            aggregates: vec![
                crate::ir::Aggregate {
                    name: "Pizza".into(),
                    description: None,
                    attributes: vec![],
                    commands: vec![crate::ir::Command {
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
                },
                crate::ir::Aggregate {
                    name: "Pizza".into(),
                    description: None,
                    attributes: vec![],
                    commands: vec![crate::ir::Command {
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
                },
            ],
            policies: vec![],
            fixtures: vec![],
        };
        let errors = validate(&domain);
        assert!(errors.iter().any(|e| e.contains("Duplicate aggregate")));
    }

    #[test]
    fn aggregate_without_commands() {
        let domain = Domain {
            name: "T".into(),
            category: None,
            aggregates: vec![crate::ir::Aggregate {
                name: "Orphan".into(),
                description: None,
                attributes: vec![],
                commands: vec![],
                value_objects: vec![],
                references: vec![],
                lifecycle: None,
            }],
            policies: vec![],
            fixtures: vec![],
        };
        let errors = validate(&domain);
        assert!(errors.iter().any(|e| e.contains("has no commands")));
    }

    #[test]
    fn bad_command_naming() {
        let domain = Domain {
            name: "T".into(),
            category: None,
            aggregates: vec![crate::ir::Aggregate {
                name: "Pizza".into(),
                description: None,
                attributes: vec![],
                commands: vec![crate::ir::Command {
                    name: "PizzaStuff".into(),
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
            }],
            policies: vec![],
            fixtures: vec![],
        };
        let errors = validate(&domain);
        assert!(errors.iter().any(|e| e.contains("doesn't start with a verb")));
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
        assert!(errors.iter().any(|e| e.contains("unknown aggregate: Widget")));
    }

    #[test]
    fn unknown_policy_trigger() {
        let domain = Domain {
            name: "T".into(),
            category: None,
            aggregates: vec![crate::ir::Aggregate {
                name: "Order".into(),
                description: None,
                attributes: vec![],
                commands: vec![crate::ir::Command {
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
            }],
            policies: vec![crate::ir::Policy {
                name: "NotifyOnOrder".into(),
                on_event: "OrderPlaced".into(),
                trigger_command: "GhostCommand".into(),
                target_domain: None,
            }],
            fixtures: vec![],
        };
        let errors = validate(&domain);
        assert!(errors.iter().any(|e| e.contains("triggers unknown command")));
    }
}
