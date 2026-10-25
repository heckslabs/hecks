//! The formatter: a parsed chapter written back out as plain sentences, one canonical wording for
//! each thing, so two authors saying the same thing leave the same text and diffs stay quiet.
//!
//! It is the reverse of `lower`: each phrase the parser reads has one spelling here, and anything
//! the sentence form has no phrase for is refused by name rather than approximated. Comments are
//! not in the IR, so they are not written.

// reason: this builds a few kilobytes of text a line at a time; an allocation per line costs
// nothing and `push_str(&format!(..))` reads as the line it writes.
#![allow(clippy::format_push_string)]

use super::changes;
use super::entity;
use super::names::spoken;
use super::options;
use super::queries;
use super::report;
use crate::ruby_value;
use crate::ir;

/// The sentence-form text of `chapter`, or the name of the construct it has no phrase for.
pub fn sentences(chapter: &ir::Bluebook) -> Result<String, String> {
    refuse_unsaid(chapter)?;
    let mut out = format!("Domain: {}\n", spoken_title(&chapter.name));
    if let Some(vision) = &chapter.vision {
        out.push_str(&format!("  {vision}\n"));
    }
    if let Some(kind) = &chapter.classification {
        out.push_str(&format!("  This is a {kind} domain\n"));
    }
    if let Some(namespace) = &chapter.namespace {
        out.push_str(&format!("  Its module is {namespace}\n"));
    }
    if let Some(version) = &chapter.version {
        if !is_word(version) {
            return Err(format!("the sentence form cannot say the version {version}"));
        }
        out.push_str(&format!("  Its version is {version}\n"));
    }
    if !chapter.attaches_to.is_empty() {
        let contexts: Vec<String> = chapter.attaches_to.iter().map(|name| spoken(name)).collect();
        out.push_str(&format!("  It attaches to {}\n", join_and(&contexts)));
    }
    provides_text(&mut out, &chapter.provides)?;
    for aggregate in &chapter.aggregates {
        out.push('\n');
        aggregate_text(&mut out, aggregate)?;
    }
    for policy in &chapter.policies {
        policy_text(&mut out, policy, chapter)?;
    }
    for model in &chapter.read_models {
        out.push_str(&report::said(model)?);
    }
    Ok(out)
}

/// `It provides authorization:` and one `key is Verb` line for each capability row.
fn provides_text(out: &mut String, provides: &[ir::Provision]) -> Result<(), String> {
    let mut current: Option<&str> = None;
    for row in provides {
        if !is_word(&row.capability) || !is_word(&row.key) || row.verb.is_empty() {
            return Err(format!("the sentence form cannot say the capability {}", row.capability));
        }
        if current != Some(row.capability.as_str()) {
            out.push_str(&format!("  It provides {}:\n", row.capability));
            current = Some(row.capability.as_str());
        }
        out.push_str(&format!("    {} is {}\n", row.key, row.verb));
    }
    Ok(())
}

/// `Policy: …` with its `Whenever` and `Then` lines.
fn policy_text(out: &mut String, policy: &ir::Policy, chapter: &ir::Bluebook) -> Result<(), String> {
    if policy.target_domain.is_some() || policy.expect_undelivered || policy.where_clause.is_some() {
        return Err(format!("the sentence form has no phrase for the options on policy {}", policy.name));
    }
    let on_event = policy
        .on_event
        .as_ref()
        .ok_or_else(|| format!("policy {} waits for no event", policy.name))?;
    out.push_str(&format!("\nPolicy: {}\n", spoken_title(&policy.name)));
    match on_event.split_once('.') {
        None => out.push_str(&format!("  Whenever the outside announces {on_event}\n")),
        Some((owner, event)) => {
            let announced_by_a_command = chapter
                .aggregates
                .iter()
                .filter(|a| a.commands.iter().any(|c| c.emits.iter().any(|e| e == event)))
                .count()
                == 1;
            if announced_by_a_command {
                out.push_str(&format!("  Whenever {event} is announced\n"));
            } else {
                out.push_str(&format!("  Whenever {event} is announced by {}\n", with_article(&spoken(owner))));
            }
        }
    }
    if let Some(query) = &policy.for_each_query {
        let (owner, name) = query.split_once('.').ok_or_else(|| {
            format!("policy {} runs for each row of '{query}', which names no aggregate", policy.name)
        })?;
        out.push_str(&format!("  For each {} of the {}\n", spoken(name), spoken(owner)));
    }
    let mut fields = Vec::new();
    for (key, value) in &policy.with_spec {
        let Some(from) = value.strip_prefix(':').filter(|from| is_name(from)) else {
            return Err(format!(
                "the sentence form passes a field on by name; policy {} passes {key} as {value}",
                policy.name
            ));
        };
        if from == key {
            fields.push(format!("the {}", spoken(key)));
        } else {
            fields.push(format!("the {} from the {}", spoken(key), spoken(from)));
        }
    }
    let with = if fields.is_empty() {
        String::new()
    } else {
        format!(" with {}", join_and(&fields))
    };
    match (&policy.trigger_command, &policy.ask) {
        (Some(command), None) => {
            let declared = chapter.aggregates.iter().any(|aggregate| {
                command.split_once('.').is_some_and(|(owner, name)| {
                    aggregate.name == owner && aggregate.commands.iter().any(|c| c.name == name)
                })
            });
            if !declared {
                return Err(format!(
                    "policy {} triggers {command}, a command this chapter does not declare",
                    policy.name
                ));
            }
            let name = command.split_once('.').map_or(command.as_str(), |(_, name)| name);
            out.push_str(&format!("  Then {} runs{with}\n", spoken_title(name)));
        }
        (None, Some(need)) => out.push_str(&format!("  Then {} is asked{with}\n", spoken(need))),
        _ => return Err(format!("policy {} must trigger a command or ask, and not both", policy.name)),
    }
    Ok(())
}

fn refuse_unsaid(chapter: &ir::Bluebook) -> Result<(), String> {
    let held = [
        (!chapter.process_managers.is_empty(), "process managers"),
    ];
    match held.iter().find(|(present, _)| *present) {
        Some((_, what)) => Err(format!("the sentence form has no phrase for {what}")),
        None => Ok(()),
    }
}

fn aggregate_text(out: &mut String, aggregate: &ir::Aggregate) -> Result<(), String> {
    block_text(out, aggregate, "Aggregate")
}

/// An aggregate, or an entity written as one, under the header `kind`.
fn block_text(out: &mut String, aggregate: &ir::Aggregate, kind: &str) -> Result<(), String> {
    let held = [
        (!aggregate.ports.is_empty(), "ports"),
    ];
    if let Some((_, what)) = held.iter().find(|(present, _)| *present) {
        return Err(format!("the sentence form has no phrase for {what}"));
    }
    let noun = spoken(&aggregate.name);
    out.push_str(&format!("{kind}: {}\n", spoken_title(&aggregate.name)));
    if let Some(description) = &aggregate.description {
        out.push_str(&format!("  {description}\n"));
    }
    if !aggregate.identified_by.is_empty() {
        let mut fields: Vec<&str> = aggregate
            .identified_by
            .iter()
            .map(|path| path.split('.').next().unwrap_or(path))
            .collect();
        fields.dedup();
        let spoken_fields: Vec<String> = fields.iter().map(|field| spoken(field)).collect();
        let possessive = if spoken_fields.len() == 1 { "its" } else { "their" };
        out.push_str(&format!(
            "\n  {} is identified by {possessive} {}.\n",
            capitalised(&with_article(&noun)),
            join_and(&spoken_fields)
        ));
    }
    for rule in &aggregate.invariants {
        out.push_str(&format!("\n  {}\n", rule_sentence("Rule", rule)?));
    }
    for precondition in &aggregate.preconditions {
        out.push_str(&format!("\n  {}\n", rule_sentence("Precondition", precondition)?));
    }
    for field in &aggregate.projected_fields {
        out.push_str(&format!(
            "\n  It shows {} as the {} of the {}\n",
            spoken(&field.name),
            spoken(&field.remote_field),
            spoken(&field.reference)
        ));
    }
    if !aggregate.attributes.is_empty() {
        out.push_str("\n  It has:\n");
        for attribute in &aggregate.attributes {
            out.push_str(&format!("    {}\n", attribute_line(attribute)?));
        }
    }
    for value_object in &aggregate.value_objects {
        value_object_text(out, value_object)?;
    }
    if let Some(lifecycle) = &aggregate.lifecycle {
        out.push_str(&format!(
            "\n  Lifecycle: {}, starting as {}\n",
            spoken(&lifecycle.field),
            lifecycle.default
        ));
        for t in &lifecycle.transitions {
            if !aggregate.commands.iter().any(|command| command.name == t.command) {
                return Err(format!("transition {} names no command {} declares", t.command, aggregate.name));
            }
            let from = t
                .from_state
                .as_ref()
                .ok_or_else(|| format!("{} moves from no state; the sentence form names one", t.command))?;
            out.push_str(&format!(
                "    {} moves {} from {from} to {}\n",
                spoken_title(&t.command),
                with_article(&noun),
                t.to_state
            ));
        }
        for (mark, states) in &lifecycle.marks {
            if !is_name(mark) || states.iter().any(|state| !is_listable(state) || state.contains(' ')) {
                return Err(format!("the sentence form cannot say the mark {mark}"));
            }
            out.push_str(&format!("    Mark {mark}: {}\n", join_and(states)));
        }
    }
    for command in &aggregate.commands {
        command_text(out, command, &noun, &aggregate.attributes)?;
    }
    for query in &aggregate.queries {
        out.push_str(&queries::said(query)?);
    }
    for entity in &aggregate.entities {
        let mut inner = String::new();
        block_text(&mut inner, &entity::as_aggregate(entity), "Entity")?;
        out.push('\n');
        for line in inner.lines() {
            out.push_str(&if line.is_empty() { String::new() } else { format!("  {line}\n") });
        }
    }
    Ok(())
}

/// The noun with its indefinite article: `a page`, `an order`.
pub(super) fn with_article(noun: &str) -> String {
    let vowel = noun.chars().next().is_some_and(|c| "aeiou".contains(c.to_ascii_lowercase()));
    format!("{} {noun}", if vowel { "an" } else { "a" })
}

fn capitalised(text: &str) -> String {
    let mut chars = text.chars();
    chars.next().map_or_else(String::new, |first| {
        first.to_uppercase().collect::<String>() + chars.as_str()
    })
}

/// `RequestRefund` -> `Request Refund`: each word capitalised, so the parser joins them back.
pub(super) fn spoken_title(name: &str) -> String {
    spoken(name)
        .split(' ')
        .map(|word| {
            let mut chars = word.chars();
            chars.next().map_or_else(String::new, |first| {
                first.to_uppercase().collect::<String>() + chars.as_str()
            })
        })
        .collect::<Vec<_>>()
        .join(" ")
}

pub(super) fn attribute_line(attribute: &ir::Attribute) -> Result<String, String> {
    let refused = || {
        format!(
            "the sentence form has no phrase for the options on attribute {}",
            attribute.name
        )
    };
    let target = attribute.reference_target();
    let form = match (attribute.relationship.as_deref(), target, attribute.list) {
        (None, None, true) => "list of ".to_string(),
        (None, None, false) => String::new(),
        (Some("reference_to"), Some(_), false) => "reference to ".to_string(),
        (Some("has_many"), Some(_), true) => "has many ".to_string(),
        _ => return Err(refused()),
    };
    let named = target.map_or_else(|| type_words(&attribute.type_name), spoken);
    Ok(format!(
        "{}: {form}{named}{}",
        with_article(&spoken(&attribute.name)),
        options::said(attribute)?
    ))
}

fn type_words(type_name: &str) -> String {
    match type_name {
        "String" => "text".to_string(),
        "Integer" => "whole number".to_string(),
        "Float" => "decimal number".to_string(),
        "Boolean" => "yes or no".to_string(),
        "TrueClass" => "true or false".to_string(),
        other => spoken(other),
    }
}

fn value_object_text(out: &mut String, value_object: &ir::ValueObject) -> Result<(), String> {
    if value_object.closed_set || !value_object.members.is_empty() {
        return closed_set_text(out, value_object);
    }
    let noun = capitalised(&with_article(&spoken(&value_object.name)));
    match value_object.attributes.as_slice() {
        [value] if value.name == "value" => {
            if value.relationship.is_some() {
                return Err(format!(
                    "the sentence form has no phrase for the options on the value of {}",
                    value_object.name
                ));
            }
            let list = if value.list { "list of " } else { "" };
            out.push_str(&format!(
                "\n  {noun} has a value: {list}{}{}.\n",
                type_words(&value.type_name),
                options::said(value)?
            ));
        }
        [] => return Err(format!("the sentence form describes {} by no attribute", value_object.name)),
        attributes => {
            out.push_str(&format!("\n  {noun} has:\n"));
            for attribute in attributes {
                out.push_str(&format!("    {}\n", attribute_line(attribute)?));
            }
        }
    }
    for rule in &value_object.invariants {
        out.push_str(&format!("    {}\n", rule_sentence("Rule", rule)?));
    }
    Ok(())
}

/// `A band is one of: small, medium and large.` for a set of text values.
fn closed_set_text(out: &mut String, value_object: &ir::ValueObject) -> Result<(), String> {
    let refused = || format!("the sentence form has no phrase for the closed set {}", value_object.name);
    let plain = matches!(
        value_object.attributes.as_slice(),
        [value] if value.name == "value" && value.type_name == "String" && !value.list && !value.optional
            && value.default.is_none() && value.pattern.is_none() && value.admits.is_none()
            && value.relationship.is_none()
    );
    if !plain || value_object.members.is_empty() {
        return Err(refused());
    }
    let mut values: Vec<String> = Vec::new();
    for member in &value_object.members {
        match member.as_slice() {
            [(column, ruby_value::Value::Str(text))] if column == "value" && is_listable(text) => values.push(text.clone()),
            _ => return Err(refused()),
        }
    }
    out.push_str(&format!(
        "\n  {} is one of: {}.\n",
        capitalised(&with_article(&spoken(&value_object.name))),
        join_and(&values)
    ));
    for rule in &value_object.invariants {
        out.push_str(&format!("    {}\n", rule_sentence("Rule", rule)?));
    }
    Ok(())
}

/// Whether `text` survives being one item of `a, b and c`: no quote, comma or colon, no inner
/// ` and `, and no leading article the reader would drop.
pub(super) fn is_listable(text: &str) -> bool {
    let first = text.split(' ').next().unwrap_or_default().to_lowercase();
    !text.is_empty()
        && text.trim() == text
        && !text.contains(['"', ',', ':'])
        && !text.split(' ').any(|word| word.eq_ignore_ascii_case("and"))
        && !matches!(first.as_str(), "a" | "an" | "the")
}

/// `Rule "…" holds when …` or `Given "…" holds when …`.
fn rule_sentence(word: &str, rule: &ir::Given) -> Result<String, String> {
    let description = rule.description.as_deref().unwrap_or_default();
    Ok(format!(
        "{word} \"{description}\" holds when {}",
        condition_words(&rule.canonical)?
    ))
}

/// The condition a canonical predicate says: in the words the Condition phrases read where one fits,
/// else as `this is true: <expression>`.
fn condition_words(canonical: &str) -> Result<String, String> {
    if let Some(field) = canonical
        .strip_prefix('!')
        .and_then(|rest| rest.strip_suffix(".to_s.empty?"))
        .filter(|field| is_name(field))
    {
        return Ok(format!("the {} is not empty", spoken(field)));
    }
    if let Some((field, number)) = canonical.split_once(" >= ") {
        if is_name(field) && !number.is_empty() && number.chars().all(|c| c.is_ascii_digit()) {
            return Ok(format!("the {} is at least {number}", spoken(field)));
        }
    }
    if let Some((field, quoted)) = canonical.split_once(" == ") {
        let value = quoted.strip_prefix('"').and_then(|rest| rest.strip_suffix('"'));
        if let Some(value) = value.filter(|value| is_word(value)) {
            if is_name(field) {
                return Ok(format!("the {} is {value}", spoken(field)));
            }
        }
    }
    // Anything the friendly phrases do not cover is said as the expression itself.
    if canonical.contains('\n') {
        return Err(format!("the sentence form cannot say a rule over several lines: `{canonical}`"));
    }
    Ok(format!("this is true: {canonical}"))
}

pub(super) fn is_name(text: &str) -> bool {
    !text.is_empty() && text.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_')
}

pub(super) fn is_word(text: &str) -> bool {
    !text.is_empty() && text.chars().all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
}

fn command_text(
    out: &mut String,
    command: &ir::Command,
    noun: &str,
    fields: &[ir::Attribute],
) -> Result<(), String> {
    let held = [
        (!command.needs.is_empty(), "needs"),
        (command.provenance.is_some(), "provenance"),
    ];
    if let Some((_, what)) = held.iter().find(|(present, _)| *present) {
        return Err(format!(
            "the sentence form has no phrase for {what} on command {}",
            command.name
        ));
    }
    out.push_str(&format!("\n  Command: {}\n", spoken_title(&command.name)));
    if let Some(goal) = &command.goal {
        out.push_str(&format!("    Goal: {goal}\n"));
    }
    if command.roles.len() > 1 {
        out.push_str(&format!("    Who: {}\n", command.roles.join(" or ")));
    } else if let Some(role) = &command.role {
        out.push_str(&format!("    Who: {role}\n"));
    }
    if let Some(from) = &command.from {
        out.push_str(&format!("    It can only happen from {}\n", states_said(&command.name, from)?));
    }
    if let Some(reference) = &command.references {
        if spoken(reference) != noun {
            return Err(format!(
                "{} acts on {reference}, which is not the aggregate it stands in",
                command.name
            ));
        }
        out.push_str(&format!("    It acts on an existing {noun}\n"));
    }
    arguments_text(out, command, fields)?;
    for given in &command.givens {
        out.push_str(&format!("    {}\n", rule_sentence("Given", given)?));
    }
    let mut outcome = "Then";
    for line in changes::said(&command.name, &command.mutations)? {
        out.push_str(&format!("    {outcome} {line}\n"));
        outcome = "And";
    }
    for event in &command.emits {
        out.push_str(&format!("    {outcome} {event} is announced\n"));
        outcome = "And";
    }
    for ensure in &command.ensures {
        out.push_str(&format!("    {}\n", rule_sentence("Afterwards", ensure)?));
    }
    Ok(())
}

/// `happen from open and frozen`: the states a command is admissible from.
fn states_said(command: &str, from: &ir::CommandFrom) -> Result<String, String> {
    let states: Vec<String> = match from {
        ir::CommandFrom::Single(state) => vec![state.clone()],
        ir::CommandFrom::Multiple(states) if states.len() > 1 => states.clone(),
        ir::CommandFrom::Multiple(_) => {
            return Err(format!("the sentence form has no phrase for a list of one state on command {command}"));
        }
    };
    if states.iter().any(|state| !is_listable(state) || state.contains(' ')) {
        return Err(format!("the sentence form cannot list the states of command {command}"));
    }
    Ok(join_and(&states))
}

/// `When a title is given`, or an `It takes:` block when an argument is its own.
fn arguments_text(out: &mut String, command: &ir::Command, fields: &[ir::Attribute]) -> Result<(), String> {
    if command.attributes.is_empty() {
        return Ok(());
    }
    let names: Result<Vec<String>, String> = command
        .attributes
        .iter()
        .map(|a| argument_name(&command.name, a, fields))
        .collect();
    if let Ok(names) = names {
        out.push_str(&format!(
            "    When {} {} given\n",
            join_and(&names),
            if names.len() == 1 { "is" } else { "are" }
        ));
        return Ok(());
    }
    out.push_str("    It takes:\n");
    for attribute in &command.attributes {
        out.push_str(&format!("      {}\n", attribute_line(attribute)?));
    }
    Ok(())
}

/// `a title`, or `an optional description`: an argument is the field of its name, optional or not.
/// Anything else about it (another type, a default, a pattern) has no phrase and is refused.
fn argument_name(command: &str, argument: &ir::Attribute, fields: &[ir::Attribute]) -> Result<String, String> {
    let field = fields.iter().find(|field| field.name == argument.name);
    let same = field.is_some_and(|field| {
        field.type_name == argument.type_name
            && field.list == argument.list
            && argument.default.is_none()
            && argument.pattern.is_none()
            && argument.admits.is_none()
            && argument.relationship.is_none()
    });
    if !same {
        return Err(format!(
            "the sentence form has no phrase for argument {} of command {command}, which differs from the field it names",
            argument.name
        ));
    }
    let spoken_name = spoken(&argument.name);
    if argument.optional {
        Ok(format!("an optional {spoken_name}"))
    } else {
        Ok(with_article(&spoken_name))
    }
}

/// `a, b and c`.
pub(super) fn join_and(items: &[String]) -> String {
    match items {
        [] => String::new(),
        [only] => only.clone(),
        [init @ .., last] => format!("{} and {last}", init.join(", ")),
    }
}
