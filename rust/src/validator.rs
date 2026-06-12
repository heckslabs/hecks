//! Domain validator — checks a parsed domain for DDD consistency
//!
//! GENERATED FILE — do not edit.
//! Source:    codegen/validator_shape/
//! Regenerate: storehouse specialize validator --output storehouse/src/validator.rs
//! Contract:  storehouse/src/specializer/validator.rs (Rust-native)
//! Tests:     storehouse/tests/validator_rules_test.rs (moved out for i51 Phase A commit 4)
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
    errors.extend(valid_policy_triggers(domain));
    errors.extend(no_duplicate_commands(domain));
    errors.extend(distinct_reference_aliases(domain));
    errors.extend(no_primitive_envy(domain));
    errors.extend(forbid_cross_aggregate_refs(domain));
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
    if domain.category.as_deref() == Some("meta") { return vec![]; }
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

    // Words ending in noun suffixes that are actually verbs
    let verb_exceptions = ["ferment", "transition", "position", "condition",
        "function", "mention", "question", "section", "fashion", "auction",
        "complement", "supplement", "implement", "segment", "cement",
        "comment", "document", "experiment", "fragment", "moment",
        "augment", "torment", "lament", "regiment"];
    if verb_exceptions.iter().any(|v| lower == *v) { return false; }

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

/// Policy triggers must name existing commands. Accepts bare names
/// (Verify) and FQN forms (Aggregate.Command, Context.Aggregate.Command)
/// per i155 — the trigger is resolved against every aggregate's command
/// list. FQN's last segment is the command name ; the prefix segments
/// must match an existing aggregate's name (and optionally context).
fn valid_policy_triggers(domain: &Domain) -> Vec<String> {
    let trigger_resolves = |trigger: &str| -> bool {
        let parts: Vec<&str> = trigger.split('.').collect();
        match parts.as_slice() {
            [cmd] => domain.aggregates.iter()
                .any(|a| a.commands.iter().any(|c| &c.name == cmd)),
            [agg, cmd] => domain.aggregates.iter()
                .any(|a| a.name == *agg
                    && a.commands.iter().any(|c| &c.name == cmd)),
            [ctx, agg, cmd] => domain.aggregates.iter()
                .any(|a| a.name == *agg
                    && a.context.as_deref() == Some(*ctx)
                    && a.commands.iter().any(|c| &c.name == cmd)),
            _ => false,
        }
    };

    domain
        .policies
        .iter()
        .filter(|p| p.target_domain.is_none()) // skip cross-domain (`across`)
        // Skip `Domain::Aggregate.Command` FQN triggers : a `::` prefix
        // names another bluebook, which a single-file validate cannot
        // see (same rationale as the cross-domain skip above). The
        // adapters-as-bluebook policies trigger `Primitive::Process.Spawn`,
        // which lives in the primitive stdlib bluebook ; whole-tree load
        // resolves it at dispatch time.
        .filter(|p| !p.trigger_command.contains("::"))
        .filter(|p| !trigger_resolves(&p.trigger_command))
        .map(|p| {
            format!(
                "Policy {} triggers unknown command: {}",
                p.name, p.trigger_command
            )
        })
        .collect()
}

/// Within an aggregate, no two commands may share the same name.
/// Across aggregates, names may collide ; FQN dispatch (Aggregate.Command)
/// disambiguates and bare-name dispatch errors on ambiguity at resolve
/// time. Per i155 — lifted from global-uniqueness to per-aggregate so
/// the UL doesn't force suffix workarounds when two aggregates share
/// a natural verb (Layout.Plan + Move.Plan, Layout.Apply + Move.Apply).
fn no_duplicate_commands(domain: &Domain) -> Vec<String> {
    let mut errors = vec![];
    for agg in &domain.aggregates {
        let mut seen = HashSet::new();
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

/// When an aggregate has multiple reference_to the same target,
/// each must carry a distinct `as:` alias — otherwise the references
/// share the same `name` and downstream consumers (event payloads,
/// generated form fields, dispatch routing) can't tell them apart.
fn distinct_reference_aliases(domain: &Domain) -> Vec<String> {
    let mut errors = vec![];
    for agg in &domain.aggregates {
        // Group references by (target, name). Any group with size > 1
        // is a collision: multiple references share the same alias.
        let mut groups: std::collections::BTreeMap<(&str, &str), usize> =
            std::collections::BTreeMap::new();
        for r in &agg.references {
            *groups.entry((r.target.as_str(), r.name.as_str())).or_insert(0) += 1;
        }
        for ((target, name), count) in &groups {
            if *count > 1 {
                errors.push(format!(
                    "{} has {} references to {} with duplicate alias {:?} — add `as: :<alias>` to each so they have distinct names",
                    agg.name, count, target, name
                ));
            }
        }
    }
    errors
}
/// Aggregate and command attributes must use typed value objects, not bare primitives.
/// Primitives belong inside value_object bodies as the storage layer, never at the
/// aggregate or command surface. No exemptions — write a value object every time.
fn no_primitive_envy(domain: &Domain) -> Vec<String> {
    const PRIMITIVES: &[&str] = &[
        "String", "Integer", "Float", "Boolean", "Date", "DateTime", "JSON",
    ];
    let mut errors = vec![];
    for agg in &domain.aggregates {
        for attr in &agg.attributes {
            if PRIMITIVES.contains(&attr.attr_type.as_str()) {
                errors.push(format!(
                    "{}.{} uses primitive type {} — wrap it in a value_object so the domain reads as itself, not as a {}",
                    agg.name, attr.name, attr.attr_type, attr.attr_type
                ));
            }
        }
        for cmd in &agg.commands {
            for attr in &cmd.attributes {
                if PRIMITIVES.contains(&attr.attr_type.as_str()) {
                    errors.push(format!(
                        "{}.{}.{} uses primitive type {} — wrap it in a value_object so the domain reads as itself, not as a {}",
                        agg.name, cmd.name, attr.name, attr.attr_type, attr.attr_type
                    ));
                }
            }
        }
    }
    errors
}

/// A given may only read its own aggregate's state — a cross-aggregate read Agg(id).field violates the consistency boundary (DDD : replicate the sibling fact via an event/policy, never read it synchronously).
fn forbid_cross_aggregate_refs(domain: &Domain) -> Vec<String> {
    let mut errors = vec![];
    for agg in &domain.aggregates {
        for cmd in &agg.commands {
            for given in &cmd.givens {
                let e = given.expression.as_bytes();
                let mut i = 0;
                while i < e.len() {
                    if (e[i] as char).is_ascii_uppercase() {
                        let start = i;
                        while i < e.len() && ((e[i] as char).is_ascii_alphanumeric() || e[i] == b'_') { i += 1; }
                        if i < e.len() && e[i] == b'(' {
                            let mut j = i + 1;
                            while j < e.len() && e[j] != b')' { j += 1; }
                            if j + 1 < e.len() && e[j] == b')' && e[j + 1] == b'.' {
                                errors.push(agg.name.clone() + "." + &cmd.name + " given has a cross-aggregate read `" + &given.expression[start..=j] + "` — a given may only read its own aggregate's state; replicate the sibling fact via an event/policy");
                                break;
                            }
                        }
                    } else { i += 1; }
                }
            }
        }
    }
    errors
}

