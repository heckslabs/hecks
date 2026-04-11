//! Generator — produce .bluebook DSL text from archetypes
//!
//! Takes a Domain IR (the archetype) and generates a new bluebook
//! with the same structural shape but placeholder names.
//!
//! Usage:
//!   let text = generate_bluebook("Geology", "study of rocks", &archetype);

use crate::ir::{Domain, Aggregate, MutationOp};

const VERSION: &str = "2026.04.11.1";

/// Generate a new bluebook from an archetype's structure.
pub fn generate_bluebook(name: &str, vision: &str, archetype: &Domain) -> String {
    let snake = to_snake(name);
    let mut out = Vec::new();
    out.push(format!("Hecks.bluebook \"{}\", version: \"{}\" do", name, VERSION));
    out.push(format!("  vision \"{}\"", vision));
    out.push(String::new());

    for agg in &archetype.aggregates {
        emit_aggregate(&mut out, agg, name);
        out.push(String::new());
    }

    for pol in &archetype.policies {
        out.push(format!("  policy \"{}\" do", pol.name));
        out.push(format!("    on \"{}\"", pol.on_event));
        out.push(format!("    trigger \"{}\"", pol.trigger_command));
        if let Some(ref td) = pol.target_domain {
            out.push(format!("    across \"{}\"", td));
        }
        out.push("  end".into());
        out.push(String::new());
    }

    if out.last().map(|l| l.is_empty()).unwrap_or(false) {
        out.pop();
    }
    out.push("end".into());

    let dir = format!("nursery/{}/{}.bluebook", snake, snake);
    out.push(String::new());
    out.push(format!("# Output: {}", dir));
    out.join("\n")
}

/// Emit a single aggregate as bluebook DSL lines. Shared by generator and evolve.
pub fn emit_aggregate(out: &mut Vec<String>, agg: &Aggregate, _domain_name: &str) {
    let desc = agg.description.as_deref().unwrap_or("TODO: describe this aggregate");
    out.push(format!("  aggregate \"{}\", \"{}\" do", agg.name, desc));

    for attr in &agg.attributes {
        let list_prefix = if attr.list { "list_of " } else { "" };
        let default_suffix = attr.default.as_ref()
            .map(|d| format!(", default: {}", d)).unwrap_or_default();
        out.push(format!("    attribute :{}, {}{}{}", attr.name, list_prefix, attr.attr_type, default_suffix));
    }

    for r in &agg.references {
        out.push(format!("    reference_to {}", r.target));
    }

    for vo in &agg.value_objects {
        out.push(format!("    value_object \"{}\" do", vo.name));
        for attr in &vo.attributes {
            out.push(format!("      attribute :{}, {}", attr.name, attr.attr_type));
        }
        out.push("    end".into());
    }

    for cmd in &agg.commands {
        emit_command(out, cmd);
    }

    if let Some(ref lc) = agg.lifecycle {
        out.push(format!("    lifecycle :{}, default: \"{}\" do", lc.field, lc.default));
        for t in &lc.transitions {
            let from = t.from_state.as_ref()
                .map(|f| format!(", from: \"{}\"", f)).unwrap_or_default();
            out.push(format!("      transition \"{}\" => \"{}\"{}", t.command, t.to_state, from));
        }
        out.push("    end".into());
    }

    out.push("  end".into());
}

fn emit_command(out: &mut Vec<String>, cmd: &crate::ir::Command) {
    out.push(format!("    command \"{}\" do", cmd.name));
    if let Some(ref role) = cmd.role {
        out.push(format!("      role \"{}\"", role));
    }
    if let Some(ref desc) = cmd.description {
        out.push(format!("      description \"{}\"", desc));
    }
    for attr in &cmd.attributes {
        out.push(format!("      attribute :{}, {}", attr.name, attr.attr_type));
    }
    for r in &cmd.references {
        out.push(format!("      reference_to {}", r.target));
    }
    if let Some(ref emits) = cmd.emits {
        out.push(format!("      emits \"{}\"", emits));
    }
    for g in &cmd.givens {
        let msg = g.message.as_ref().map(|m| format!(" \"{}\"", m)).unwrap_or_default();
        out.push(format!("      given{} {{ {} }}", msg, g.expression));
    }
    for m in &cmd.mutations {
        let op = match m.operation {
            MutationOp::Set => format!("then_set :{}, to: {}", m.field, m.value),
            MutationOp::Append => format!("then_set :{}, append: {}", m.field, m.value),
            MutationOp::Increment => format!("then_set :{}, increment: {}", m.field, m.value),
            MutationOp::Decrement => format!("then_set :{}, decrement: {}", m.field, m.value),
            MutationOp::Toggle => format!("then_toggle :{}", m.field),
        };
        out.push(format!("      {}", op));
    }
    out.push("    end".into());
}

fn to_snake(s: &str) -> String {
    let mut result = String::new();
    for (i, c) in s.chars().enumerate() {
        if c.is_uppercase() && i > 0 { result.push('_'); }
        if c.is_whitespace() { result.push('_'); }
        else { result.push(c.to_lowercase().next().unwrap()); }
    }
    result
}
