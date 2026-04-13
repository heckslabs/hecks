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

/// Command names must start with a verb — detected by morphological patterns.
/// Flipped logic: a command is imperative by definition. We only reject if
/// the first word is provably NOT a verb (noun/adjective suffixes).
/// Everything else passes — commands are verbs until proven otherwise.

/// Suffixes that prove a word is a noun — not a verb.
const NOUN_SUFFIXES: &[&str] = &[
    "tion", "sion", "ment", "ness", "ity", "ence", "ance",
    "ology", "ism", "ist", "dom", "ship",
];

/// Suffixes that prove a word is an adjective — not a verb.
const ADJ_SUFFIXES: &[&str] = &[
    "able", "ible", "ous", "ful", "less", "ive", "ical", "ular",
];

/// Words that look like they could be verbs but are actually nouns
/// when used as command first-words. Very short list — only add
/// proven false positives.
const FALSE_POSITIVES: &[&str] = &[
    "The", "A", "An", "My", "Our", "New", "Old",
];

/// Extract the first word from a PascalCase name.
fn first_word(name: &str) -> String {
    let mut word = String::new();
    for (i, c) in name.chars().enumerate() {
        if i > 0 && c.is_uppercase() { break; }
        word.push(c);
    }
    word
}

/// A command first-word is NOT a verb if it matches noun/adjective patterns.
/// Everything else is assumed to be a verb — commands are imperative.
fn is_not_verb(word: &str) -> bool {
    let lower = word.to_lowercase();

    // Too short to classify — single char is fine (commands like "X" are weird but not invalid)
    if lower.len() < 2 { return false; }

    // Known false positives — articles, possessives, adjectives used as names
    if FALSE_POSITIVES.iter().any(|fp| *fp == word) { return true; }

    // Verb suffixes — if these match, the word is a verb even if it
    // also matches a noun/adjective suffix (verb wins)
    let verb_suffixes = ["ive", "ence", "ance", "ise", "ize", "ate", "ify",
        "uce", "ude", "ose", "ure", "ect", "mit", "ish", "rge", "ve"];
    let has_verb_suffix = verb_suffixes.iter().any(|s| lower.ends_with(s));

    // Noun suffixes — if it ends like a noun AND doesn't have a verb suffix, reject
    for suffix in NOUN_SUFFIXES {
        if lower.ends_with(suffix) && lower.len() > suffix.len() + 1 && !has_verb_suffix {
            return true;
        }
    }

    // Adjective suffixes — same logic
    for suffix in ADJ_SUFFIXES {
        if lower.ends_with(suffix) && lower.len() > suffix.len() + 1 && !has_verb_suffix {
            return true;
        }
    }

    // Everything else is a verb. Commands are imperative by definition.
    false
}

fn command_naming(domain: &Domain) -> Vec<String> {
    let mut errors = vec![];
    for agg in &domain.aggregates {
        for cmd in &agg.commands {
            let word = first_word(&cmd.name);
            if is_not_verb(&word) {
                errors.push(format!(
                    "Command {} in {} starts with '{}' which looks like a {} — commands should start with a verb",
                    cmd.name, agg.name, word,
                    if NOUN_SUFFIXES.iter().any(|s| word.to_lowercase().ends_with(s)) { "noun" } else { "adjective" }
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
