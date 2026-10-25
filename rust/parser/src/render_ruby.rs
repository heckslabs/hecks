//! Renders a parsed chapter as the Ruby-shaped bluebook text that declares the same IR.
//!
//! A chapter written as sentences is run by Ruby through this text: `hecks-parse render` prints
//! it and Ruby loads it like any other `.bluebook`. It spells only what the sentence form can
//! say; anything else is refused by name rather than guessed at.

// reason: this builds a few kilobytes of text a line at a time; an allocation per line costs
// nothing and `push_str(&format!(..))` reads as the line it writes.
#![allow(clippy::format_push_string)]

use crate::ir;

/// The Ruby-form text of `chapter`, or the name of the construct it has no spelling for.
pub fn ruby_form(chapter: &ir::Bluebook) -> Result<String, String> {
    let mut out = String::new();
    out.push_str(&format!("Hecks.bluebook {} do\n", string(&chapter.name)));
    if let Some(vision) = &chapter.vision {
        out.push_str(&format!("  vision {}\n", string(vision)));
    }
    refuse_unspelt(chapter)?;
    for aggregate in &chapter.aggregates {
        out.push('\n');
        aggregate_text(&mut out, aggregate)?;
    }
    for policy in &chapter.policies {
        policy_text(&mut out, policy)?;
    }
    out.push_str("end\n");
    Ok(out)
}

/// `policy "Name" do … end`: the event it waits for and the command it runs or the need it asks.
fn policy_text(out: &mut String, policy: &ir::Policy) -> Result<(), String> {
    if policy.target_domain.is_some()
        || policy.expect_undelivered
        || policy.where_clause.is_some()
        || policy.for_each_query.is_some()
    {
        return Err(format!(
            "the Ruby renderer has no spelling for the options on policy {}",
            policy.name
        ));
    }
    let on_event = policy
        .on_event
        .as_ref()
        .ok_or_else(|| format!("policy {} waits for no event", policy.name))?;
    out.push_str(&format!("\n  policy {} do\n    on {}\n", string(&policy.name), string(on_event)));
    let with = if policy.with_spec.is_empty() {
        String::new()
    } else {
        let pairs: Vec<String> = policy.with_spec.iter().map(|(key, value)| format!("{key}: {value}")).collect();
        format!(", with: {{ {} }}", pairs.join(", "))
    };
    match (&policy.trigger_command, &policy.ask) {
        (Some(command), None) => {
            out.push_str(&format!("    trigger {}{with}\n", command.replace('.', "::")));
        }
        (None, Some(need)) => out.push_str(&format!("    ask :{need}{with}\n")),
        _ => return Err(format!("policy {} must trigger a command or ask, and not both", policy.name)),
    }
    out.push_str("  end\n");
    Ok(())
}

fn refuse_unspelt(chapter: &ir::Bluebook) -> Result<(), String> {
    let held = [
        (!chapter.read_models.is_empty(), "read models"),
        (!chapter.process_managers.is_empty(), "process managers"),
        (!chapter.provides.is_empty(), "provided capabilities"),
        (!chapter.attaches_to.is_empty(), "attaches"),
        (chapter.version.is_some(), "a version"),
    ];
    match held.iter().find(|(present, _)| *present) {
        Some((_, what)) => Err(format!("the Ruby renderer has no spelling for {what}")),
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
        return Err(format!("the Ruby renderer has no spelling for {what}"));
    }
    out.push_str(&format!("  aggregate {} do\n", string(&aggregate.name)));
    if let Some(description) = &aggregate.description {
        out.push_str(&format!("    description {}\n", string(description)));
    }
    if !aggregate.identified_by.is_empty() {
        let mut fields: Vec<&str> = aggregate
            .identified_by
            .iter()
            .map(|path| path.split('.').next().unwrap_or(path))
            .collect();
        fields.dedup();
        let symbols: Vec<String> = fields.iter().map(|field| format!(":{field}")).collect();
        out.push_str(&format!("    identified_by {}\n", symbols.join(", ")));
    }
    if !aggregate.attributes.is_empty() {
        out.push('\n');
    }
    for attribute in &aggregate.attributes {
        out.push_str(&format!("    {}\n", attribute_line(attribute)?));
    }
    for value_object in &aggregate.value_objects {
        value_object_text(out, value_object)?;
    }
    if let Some(lifecycle) = &aggregate.lifecycle {
        lifecycle_text(out, lifecycle);
    }
    for command in &aggregate.commands {
        command_text(out, command)?;
    }
    for query in &aggregate.queries {
        query_text(out, query)?;
    }
    out.push_str("  end\n");
    Ok(())
}

fn attribute_line(attribute: &ir::Attribute) -> Result<String, String> {
    if attribute.default.is_some()
        || attribute.pattern.is_some()
        || attribute.admits.is_some()
        || attribute.relationship.is_some()
    {
        return Err(format!(
            "the Ruby renderer has no spelling for the options on attribute {}",
            attribute.name
        ));
    }
    let type_name = if attribute.list {
        format!("list_of({})", attribute.type_name)
    } else {
        attribute.type_name.clone()
    };
    let optional = if attribute.optional { ", optional: true" } else { "" };
    Ok(format!("attribute :{}, {type_name}{optional}", attribute.name))
}

fn value_object_text(out: &mut String, value_object: &ir::ValueObject) -> Result<(), String> {
    if value_object.closed_set || !value_object.members.is_empty() {
        return Err(format!(
            "the Ruby renderer has no spelling for the closed set {}",
            value_object.name
        ));
    }
    out.push_str(&format!("\n    value_object {} do\n", string(&value_object.name)));
    for attribute in &value_object.attributes {
        out.push_str(&format!("      {}\n", attribute_line(attribute)?));
    }
    for invariant in &value_object.invariants {
        out.push_str(&format!("      {}\n", rule_line("invariant", invariant)));
    }
    out.push_str("    end\n");
    Ok(())
}

fn rule_line(word: &str, rule: &ir::Given) -> String {
    format!(
        "{word}({}) {{ {} }}",
        string(rule.description.as_deref().unwrap_or_default()),
        rule.canonical
    )
}

fn lifecycle_text(out: &mut String, lifecycle: &ir::Lifecycle) {
    out.push_str(&format!(
        "\n    lifecycle :{}, default: {} do\n",
        lifecycle.field,
        string(&lifecycle.default)
    ));
    for t in &lifecycle.transitions {
        let from = t
            .from_state
            .as_ref()
            .map_or_else(String::new, |from| format!(", from: {}", string(from)));
        out.push_str(&format!(
            "      transition {} => {}{from}\n",
            string(&t.command),
            string(&t.to_state)
        ));
    }
    out.push_str("    end\n");
}

fn command_text(out: &mut String, command: &ir::Command) -> Result<(), String> {
    let held = [
        (!command.ensures.is_empty(), "ensures"),
        (!command.needs.is_empty(), "needs"),
        (command.from.is_some(), "from"),
        (command.provenance.is_some(), "provenance"),
    ];
    if let Some((_, what)) = held.iter().find(|(present, _)| *present) {
        return Err(format!(
            "the Ruby renderer has no spelling for {what} on command {}",
            command.name
        ));
    }
    out.push_str(&format!("\n    command {} do\n", string(&command.name)));
    if command.roles.len() > 1 {
        let roles: Vec<String> = command.roles.iter().map(|role| string(role)).collect();
        out.push_str(&format!("      role {}\n", roles.join(", ")));
    } else if let Some(role) = &command.role {
        out.push_str(&format!("      role {}\n", string(role)));
    }
    if let Some(goal) = &command.goal {
        out.push_str(&format!("      goal {}\n", string(goal)));
    }
    if let Some(reference) = &command.references {
        out.push_str(&format!("      reference_to {reference}\n"));
    }
    for attribute in &command.attributes {
        out.push_str(&format!("      {}\n", attribute_line(attribute)?));
    }
    for given in &command.givens {
        out.push_str(&format!("      {}\n", rule_line("given", given)));
    }
    for mutation in &command.mutations {
        out.push_str(&format!("      {}\n", mutation_line(&command.name, mutation)?));
    }
    for event in &command.emits {
        out.push_str(&format!("      emits {}\n", string(event)));
    }
    out.push_str("    end\n");
    Ok(())
}

fn mutation_line(command: &str, mutation: &ir::Mutation) -> Result<String, String> {
    match mutation {
        ir::Mutation::Other {
            target,
            op,
            source: Some(ir::MutationSource::Argument(argument)),
            ..
        } if op == "set" => Ok(if argument == target {
            format!("sets :{target}")
        } else {
            format!("sets :{target}, to: :{argument}")
        }),
        _ => Err(format!(
            "the Ruby renderer has no spelling for that kind of mutation on command {command}"
        )),
    }
}

fn query_text(out: &mut String, query: &ir::Query) -> Result<(), String> {
    if query.limit.is_some()
        || !query.attributes.is_empty()
        || !query.needs.is_empty()
        || query.returns.is_some()
    {
        return Err(format!(
            "the Ruby renderer has no spelling for the options on query {}",
            query.name
        ));
    }
    out.push_str(&format!("\n    query {} do\n", string(&query.name)));
    if let Some(description) = &query.description {
        out.push_str(&format!("      description {}\n", string(description)));
    }
    for clause in &query.wheres {
        if clause.op != "eq" || clause.target.is_some() {
            return Err(format!(
                "the Ruby renderer has no spelling for a {} comparison in query {}",
                clause.op, query.name
            ));
        }
        out.push_str(&format!("      where({}: {})\n", clause.field, clause.value));
    }
    if let Some(order) = &query.order_by {
        out.push_str(&format!(
            "      order_by :{}, :{}\n",
            string(&order.field),
            order.direction
        ));
    }
    out.push_str("    end\n");
    Ok(())
}

/// A Ruby double-quoted string literal for `text`.
pub fn string(text: &str) -> String {
    let mut out = String::from("\"");
    for c in text.chars() {
        match c {
            '\\' => out.push_str("\\\\"),
            '"' => out.push_str("\\\""),
            '#' => out.push_str("\\#"),
            '\n' => out.push_str("\\n"),
            other => out.push(other),
        }
    }
    out.push('"');
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_string_is_quoted_so_ruby_reads_it_back_unchanged() {
        assert_eq!(string("say \"hi\" #{now}"), "\"say \\\"hi\\\" \\#{now}\"");
    }

    #[test]
    fn a_read_model_has_no_spelling_yet() {
        let chapter = ir::Bluebook {
            name: "X".to_string(),
            read_models: vec![ir::ReadModel::default()],
            ..Default::default()
        };
        assert!(ruby_form(&chapter).is_err_and(|why| why.contains("read models")));
    }
}
