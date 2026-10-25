//! The formatter: a parsed chapter written back out as plain sentences, one canonical wording for
//! each thing, so two authors saying the same thing leave the same text and diffs stay quiet.
//!
//! It is the reverse of `lower`: each phrase the parser reads has one spelling here, and anything
//! the sentence form has no phrase for is refused by name rather than approximated. Comments are
//! not in the IR, so they are not written.

// reason: this builds a few kilobytes of text a line at a time; an allocation per line costs
// nothing and `push_str(&format!(..))` reads as the line it writes.
#![allow(clippy::format_push_string)]

use super::names::spoken;
use super::options;
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
    for aggregate in &chapter.aggregates {
        out.push('\n');
        aggregate_text(&mut out, aggregate)?;
    }
    for policy in &chapter.policies {
        policy_text(&mut out, policy, chapter)?;
    }
    Ok(out)
}

/// `Policy: …` with its `Whenever` and `Then` lines.
fn policy_text(out: &mut String, policy: &ir::Policy, chapter: &ir::Bluebook) -> Result<(), String> {
    if policy.target_domain.is_some()
        || policy.expect_undelivered
        || policy.where_clause.is_some()
        || policy.for_each_query.is_some()
    {
        return Err(format!("the sentence form has no phrase for the options on policy {}", policy.name));
    }
    let on_event = policy
        .on_event
        .as_ref()
        .ok_or_else(|| format!("policy {} waits for no event", policy.name))?;
    let (owner, event) = on_event
        .split_once('.')
        .ok_or_else(|| format!("policy {} waits for '{on_event}', which names no aggregate", policy.name))?;
    out.push_str(&format!("\nPolicy: {}\n", spoken_title(&policy.name)));
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
    let mut fields = Vec::new();
    for (key, value) in &policy.with_spec {
        if *value != format!(":{key}") {
            return Err(format!(
                "the sentence form passes a field on by its own name; policy {} passes {key} as {value}",
                policy.name
            ));
        }
        fields.push(format!("the {}", spoken(key)));
    }
    let with = if fields.is_empty() {
        String::new()
    } else {
        format!(" with {}", join_and(&fields))
    };
    match (&policy.trigger_command, &policy.ask) {
        (Some(command), None) => {
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
        (!chapter.read_models.is_empty(), "read models"),
        (!chapter.process_managers.is_empty(), "process managers"),
        (!chapter.provides.is_empty(), "provided capabilities"),
        (!chapter.attaches_to.is_empty(), "attaches"),
        (chapter.version.is_some(), "a version"),
    ];
    match held.iter().find(|(present, _)| *present) {
        Some((_, what)) => Err(format!("the sentence form has no phrase for {what}")),
        None => Ok(()),
    }
}

fn aggregate_text(out: &mut String, aggregate: &ir::Aggregate) -> Result<(), String> {
    let held = [
        (!aggregate.entities.is_empty(), "entities"),
        (!aggregate.ports.is_empty(), "ports"),
        (!aggregate.invariants.is_empty(), "aggregate invariants"),
        (!aggregate.preconditions.is_empty(), "preconditions"),
        (!aggregate.projected_fields.is_empty(), "projected fields"),
    ];
    if let Some((_, what)) = held.iter().find(|(present, _)| *present) {
        return Err(format!("the sentence form has no phrase for {what}"));
    }
    let noun = spoken(&aggregate.name);
    out.push_str(&format!("Aggregate: {}\n", spoken_title(&aggregate.name)));
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
        let [field] = fields.as_slice() else {
            return Err("the sentence form identifies an aggregate by one field".to_string());
        };
        out.push_str(&format!(
            "\n  {} is identified by its {}.\n",
            capitalised(&with_article(&noun)),
            spoken(field)
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
    }
    for command in &aggregate.commands {
        command_text(out, command, &noun, &aggregate.attributes)?;
    }
    for query in &aggregate.queries {
        query_text(out, query)?;
    }
    Ok(())
}

/// The noun with its indefinite article: `a page`, `an order`.
fn with_article(noun: &str) -> String {
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
fn spoken_title(name: &str) -> String {
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

fn attribute_line(attribute: &ir::Attribute) -> Result<String, String> {
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
fn is_listable(text: &str) -> bool {
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

fn is_name(text: &str) -> bool {
    !text.is_empty() && text.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_')
}

fn is_word(text: &str) -> bool {
    !text.is_empty() && text.chars().all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
}

fn command_text(
    out: &mut String,
    command: &ir::Command,
    noun: &str,
    fields: &[ir::Attribute],
) -> Result<(), String> {
    let held = [
        (!command.ensures.is_empty(), "ensures"),
        (!command.needs.is_empty(), "needs"),
        (command.from.is_some(), "from"),
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
    if let Some(reference) = &command.references {
        if spoken(reference) != noun {
            return Err(format!(
                "{} acts on {reference}, which is not the aggregate it stands in",
                command.name
            ));
        }
        out.push_str(&format!("    It acts on an existing {noun}\n"));
    }
    if !command.attributes.is_empty() {
        let names: Vec<String> = command
            .attributes
            .iter()
            .map(|a| argument_name(&command.name, a, fields))
            .collect::<Result<_, _>>()?;
        out.push_str(&format!(
            "    When {} {} given\n",
            join_and(&names),
            if names.len() == 1 { "is" } else { "are" }
        ));
    }
    for given in &command.givens {
        out.push_str(&format!("    {}\n", rule_sentence("Given", given)?));
    }
    let mut outcome = "Then";
    if !command.mutations.is_empty() {
        let names: Vec<String> = command
            .mutations
            .iter()
            .map(|m| set_name(&command.name, m))
            .collect::<Result<_, _>>()?;
        out.push_str(&format!(
            "    {outcome} {} {} set\n",
            join_and(&names),
            if names.len() == 1 { "is" } else { "are" }
        ));
        outcome = "And";
    }
    for event in &command.emits {
        out.push_str(&format!("    {outcome} {event} is announced\n"));
        outcome = "And";
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

fn set_name(command: &str, mutation: &ir::Mutation) -> Result<String, String> {
    match mutation {
        ir::Mutation::Other {
            target,
            op,
            source: Some(ir::MutationSource::Argument(argument)),
            ..
        } if op == "set" && argument == target => Ok(format!("the {}", spoken(target))),
        _ => Err(format!(
            "the sentence form has no phrase for that kind of mutation on command {command}"
        )),
    }
}

/// `a, b and c`.
fn join_and(items: &[String]) -> String {
    match items {
        [] => String::new(),
        [only] => only.clone(),
        [init @ .., last] => format!("{} and {last}", init.join(", ")),
    }
}

fn query_text(out: &mut String, query: &ir::Query) -> Result<(), String> {
    if query.limit.is_some()
        || !query.attributes.is_empty()
        || !query.needs.is_empty()
        || query.returns.is_some()
    {
        return Err(format!(
            "the sentence form has no phrase for the options on query {}",
            query.name
        ));
    }
    out.push_str(&format!("\n  Query: {}\n", spoken_title(&query.name)));
    if let Some(description) = &query.description {
        out.push_str(&format!("    {description}\n"));
    }
    for clause in &query.wheres {
        let value = clause
            .value
            .strip_prefix('"')
            .and_then(|rest| rest.strip_suffix('"'))
            .filter(|value| clause.op == "eq" && clause.target.is_none() && is_word(value) && is_name(&clause.field))
            .ok_or_else(|| {
                format!(
                    "the sentence form has no phrase for a {} comparison in query {}",
                    clause.op, query.name
                )
            })?;
        out.push_str(&format!("    Where the {} is {value}\n", spoken(&clause.field)));
    }
    if let Some(order) = &query.order_by {
        let direction = if order.direction == "desc" { "descending" } else { "ascending" };
        out.push_str(&format!("    Ordered by {}, {direction}\n", order.field));
    }
    Ok(())
}
