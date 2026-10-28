//! Renders a parsed bluebook as the Ruby-shaped bluebook text that declares the same IR.
//!
//! A bluebook written as sentences is run by Ruby through this text: `hecks-parse render` prints
//! it and Ruby loads it like any other `.bluebook`. It spells only what the sentence form can
//! say; anything else is refused by name rather than guessed at.

// reason: this builds a few kilobytes of text a line at a time; an allocation per line costs
// nothing and `push_str(&format!(..))` reads as the line it writes.
#![allow(clippy::format_push_string)]

use crate::ir;

/// The Ruby-form text of `bluebook`, or the name of the construct it has no spelling for.
pub fn ruby_form(declaration: &ir::Bluebook) -> Result<String, String> {
    let mut out = String::new();
    out.push_str(&format!(
        "Hecks.bluebook {} do\n",
        string(&declaration.name)
    ));
    if let Some(vision) = &declaration.vision {
        out.push_str(&format!("  vision {}\n", string(vision)));
    }
    out.push_str(&classification_line(declaration.classification.as_deref())?);
    refuse_unspelt(declaration)?;
    for aggregate in &declaration.aggregates {
        out.push('\n');
        aggregate_text(&mut out, aggregate)?;
    }
    for policy in &declaration.policies {
        policy_text(&mut out, policy)?;
    }
    out.push_str("end\n");
    Ok(out)
}

/// The bare `core`, `supporting` or `generic` word that classifies a bluebook, or nothing.
fn classification_line(classification: Option<&str>) -> Result<String, String> {
    match classification {
        None => Ok(String::new()),
        Some(word @ ("core" | "supporting" | "generic")) => Ok(format!("  {word}\n")),
        Some(other) => Err(format!(
            "the Ruby renderer has no spelling for the classification {other}"
        )),
    }
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
    out.push_str(&format!(
        "\n  policy {} do\n    on {}\n",
        string(&policy.name),
        string(on_event)
    ));
    let with = if policy.with_spec.is_empty() {
        String::new()
    } else {
        let pairs: Vec<String> = policy
            .with_spec
            .iter()
            .map(|(key, value)| format!("{key}: {value}"))
            .collect();
        format!(", with: {{ {} }}", pairs.join(", "))
    };
    match (&policy.trigger_command, &policy.ask) {
        (Some(command), None) => {
            out.push_str(&format!(
                "    trigger {}{with}\n",
                command.replace('.', "::")
            ));
        }
        (None, Some(need)) => out.push_str(&format!("    ask :{need}{with}\n")),
        _ => {
            return Err(format!(
                "policy {} must trigger a command or ask, and not both",
                policy.name
            ))
        }
    }
    out.push_str("  end\n");
    Ok(())
}

fn refuse_unspelt(declaration: &ir::Bluebook) -> Result<(), String> {
    let held = [
        (!declaration.read_models.is_empty(), "read models"),
        (!declaration.process_managers.is_empty(), "process managers"),
        (!declaration.provides.is_empty(), "provided capabilities"),
        (!declaration.attaches_to.is_empty(), "attaches"),
        (declaration.version.is_some(), "a version"),
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
        (!aggregate.acknowledgements.is_empty(), "acknowledgements"),
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
    if attribute.default.is_some() || attribute.admits.is_some() || attribute.relationship.is_some()
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
    let optional = if attribute.optional {
        ", optional: true"
    } else {
        ""
    };
    let pattern = attribute
        .pattern
        .as_deref()
        .map(pattern_option)
        .unwrap_or_default();
    Ok(format!(
        "attribute :{}, {type_name}{optional}{pattern}",
        attribute.name
    ))
}

/// The keyword option that states a pattern: `matches: :name` when the language names exactly that
/// regex, else the raw `pattern:`.
fn pattern_option(source: &str) -> String {
    crate::build::named_pattern::name_of(source).map_or_else(
        || format!(", pattern: {}", string(source)),
        |name| format!(", matches: :{name}"),
    )
}

fn value_object_text(out: &mut String, value_object: &ir::ValueObject) -> Result<(), String> {
    let closed = closed_set_line(value_object);
    if (value_object.closed_set || !value_object.members.is_empty()) && closed.is_none() {
        return Err(format!(
            "the Ruby renderer has no spelling for the closed set {}",
            value_object.name
        ));
    }
    out.push_str(&format!(
        "\n    value_object {} do\n",
        string(&value_object.name)
    ));
    match closed {
        Some(line) => out.push_str(&format!("      {line}\n")),
        None => {
            for attribute in &value_object.attributes {
                out.push_str(&format!("      {}\n", attribute_line(attribute)?));
            }
        }
    }
    for invariant in &value_object.invariants {
        out.push_str(&format!("      {}\n", rule_line("invariant", invariant)));
    }
    out.push_str("    end\n");
    Ok(())
}

/// The `attribute :value, String, one_of: [...]` line of a closed set whose members each name the
/// value object's only attribute, else `None`: any other closed set has no Ruby spelling here.
fn closed_set_line(value_object: &ir::ValueObject) -> Option<String> {
    let [attribute] = value_object.attributes.as_slice() else {
        return None;
    };
    if !value_object.closed_set || attribute_line(attribute).is_err() {
        return None;
    }
    let values: Option<Vec<String>> = value_object
        .members
        .iter()
        .map(|member| match member.as_slice() {
            [(field, value)] if *field == attribute.name => Some(crate::ruby_value::render(value)),
            _ => None,
        })
        .collect();
    let line = attribute_line(attribute).ok()?;
    Some(format!("{line}, one_of: [{}]", values?.join(", ")))
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
    for (mark, states) in &lifecycle.marks {
        let spelt: Vec<String> = states.iter().map(|state| string(state)).collect();
        out.push_str(&format!("      mark :{mark}, {}\n", spelt.join(", ")));
    }
    out.push_str("    end\n");
}

fn command_text(out: &mut String, command: &ir::Command) -> Result<(), String> {
    let held = [
        (!command.ensures.is_empty(), "ensures"),
        (!command.needs.is_empty(), "needs"),
        (command.provenance.is_some(), "provenance"),
    ];
    if let Some((_, what)) = held.iter().find(|(present, _)| *present) {
        return Err(format!(
            "the Ruby renderer has no spelling for {what} on command {}",
            command.name
        ));
    }
    out.push_str(&format!(
        "\n    command {}{} do\n",
        string(&command.name),
        from_option(command.from.as_ref())
    ));
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
        out.push_str(&format!(
            "      {}\n",
            mutation_line(&command.name, mutation)?
        ));
    }
    for event in &command.emits {
        out.push_str(&format!("      emits {}\n", string(event)));
    }
    out.push_str("    end\n");
    Ok(())
}

/// The `, from: ...` option that limits a command to lifecycle states, or nothing.
fn from_option(from: Option<&ir::CommandFrom>) -> String {
    match from {
        None => String::new(),
        Some(ir::CommandFrom::Single(state)) => format!(", from: {}", string(state)),
        Some(ir::CommandFrom::Multiple(states)) => {
            let spelt: Vec<String> = states.iter().map(|state| string(state)).collect();
            format!(", from: [{}]", spelt.join(", "))
        }
    }
}

fn mutation_line(command: &str, mutation: &ir::Mutation) -> Result<String, String> {
    match mutation {
        ir::Mutation::Append { target, fields } => {
            let pairs: Vec<String> = fields
                .iter()
                .map(|(key, spelling)| format!("{key}: {spelling}"))
                .collect();
            Ok(format!(
                "sets :{target}, append: {{ {} }}",
                pairs.join(", ")
            ))
        }
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
    if query.limit.is_some() || !query.needs.is_empty() || query.returns.is_some() {
        return Err(format!(
            "the Ruby renderer has no spelling for the options on query {}",
            query.name
        ));
    }
    out.push_str(&format!("\n    query {} do\n", string(&query.name)));
    if let Some(description) = &query.description {
        out.push_str(&format!("      description {}\n", string(description)));
    }
    for attribute in &query.attributes {
        out.push_str(&format!("      {}\n", attribute_line(attribute)?));
    }
    for clause in &query.wheres {
        out.push_str(&format!("      {}\n", where_line(&query.name, clause)?));
    }
    if let Some(order) = &query.order_by {
        out.push_str(&format!(
            "      order_by :{}, :{}\n",
            string(&order.field),
            order.direction
        ));
    }
    if let Some(mode) = &query.options.null_semantics {
        out.push_str(&format!("      nulls :{mode}\n"));
    }
    out.push_str("    end\n");
    Ok(())
}

/// `where(field: value)` for an equality, `where(:"a.b" => { op: value })` for any other comparison.
fn where_line(query: &str, clause: &ir::WhereClause) -> Result<String, String> {
    if clause.target.is_some() {
        return Err(format!(
            "the Ruby renderer has no spelling for a targeted comparison in query {query}"
        ));
    }
    Ok(if clause.op == "eq" {
        format!("where({}: {})", clause.field, clause.value)
    } else {
        format!(
            "where({} => {{ {}: {} }})",
            ruby_symbol(&clause.field),
            clause.op,
            clause.value
        )
    })
}

/// `:name` for a plain word, `:"a.b"` for a dotted path.
fn ruby_symbol(name: &str) -> String {
    if name.chars().all(|c| c.is_ascii_alphanumeric() || c == '_') {
        format!(":{name}")
    } else {
        format!(":{}", string(name))
    }
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

    fn attribute(name: &str, type_name: &str) -> ir::Attribute {
        ir::Attribute {
            name: name.to_string(),
            type_name: type_name.to_string(),
            ..Default::default()
        }
    }

    #[test]
    fn a_named_pattern_is_written_as_matches() {
        let mut held = attribute("value", "String");
        held.pattern = Some(r"[^ \t\n\r]".to_string());
        assert_eq!(
            attribute_line(&held).unwrap(),
            "attribute :value, String, matches: :present"
        );
    }

    #[test]
    fn an_unnamed_pattern_is_written_as_pattern() {
        let mut held = attribute("code", "String");
        held.pattern = Some("^[A-Z]{3}$".to_string());
        assert_eq!(
            attribute_line(&held).unwrap(),
            "attribute :code, String, pattern: \"^[A-Z]{3}$\""
        );
    }

    #[test]
    fn a_closed_set_of_one_attribute_is_written_as_one_of() {
        let member = |value: &str| {
            vec![(
                "value".to_string(),
                crate::ruby_value::Value::Str(value.to_string()),
            )]
        };
        let size = ir::ValueObject {
            name: "Size".to_string(),
            attributes: vec![attribute("value", "String")],
            closed_set: true,
            members: vec![member("small"), member("large")],
            ..Default::default()
        };
        assert_eq!(
            closed_set_line(&size).unwrap(),
            "attribute :value, String, one_of: [\"small\", \"large\"]"
        );
    }

    #[test]
    fn a_command_limited_to_states_is_written_with_from() {
        let one = ir::CommandFrom::Single("available".to_string());
        let many = ir::CommandFrom::Multiple(vec!["a".to_string(), "b".to_string()]);
        assert_eq!(from_option(Some(&one)), ", from: \"available\"");
        assert_eq!(from_option(Some(&many)), ", from: [\"a\", \"b\"]");
        assert_eq!(from_option(None), "");
    }

    #[test]
    fn a_comparison_other_than_equality_is_written_against_a_symbol_key() {
        let clause = ir::WhereClause {
            field: "pizza.price_cents.cents".to_string(),
            op: "lt".to_string(),
            value: ":ceiling".to_string(),
            target: None,
        };
        assert_eq!(
            where_line("CostingLessThan", &clause).unwrap(),
            "where(:\"pizza.price_cents.cents\" => { lt: :ceiling })"
        );
    }

    #[test]
    fn a_classification_is_a_bare_word() {
        assert_eq!(
            classification_line(Some("supporting")).unwrap(),
            "  supporting\n"
        );
        assert_eq!(classification_line(None).unwrap(), "");
        assert!(classification_line(Some("odd")).is_err());
    }

    #[test]
    fn a_read_model_has_no_spelling_yet() {
        let declaration = ir::Bluebook {
            name: "X".to_string(),
            read_models: vec![ir::ReadModel::default()],
            ..Default::default()
        };
        assert!(ruby_form(&declaration).is_err_and(|why| why.contains("read models")));
    }
}
