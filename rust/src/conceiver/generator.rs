//! Generator — produce .bluebook DSL text from archetypes
//!
//! Takes a Domain IR (the archetype) and generates a new bluebook
//! with the same structural shape but placeholder names.
//!
//! Usage:
//!   let text = generate_bluebook("Geology", "study of rocks", &archetype);

use crate::ir::{Domain, Aggregate, MutationOp};

const VERSION: &str = "2026.04.11.1";

/// Generate a scaffold bluebook from an archetype's structure.
/// Outputs the right shape with placeholder names — you fill in the vocabulary.
pub fn generate_bluebook(name: &str, vision: &str, archetype: &Domain) -> String {
    let snake = to_snake(name);
    let mut out = Vec::new();
    out.push(format!("Hecks.bluebook \"{}\", version: \"{}\" do", name, VERSION));
    out.push(format!("  vision \"{}\"", vision));
    if let Some(ref cat) = archetype.category {
        out.push(format!("  category \"{}\"", cat));
    }
    out.push(String::new());

    for (i, agg) in archetype.aggregates.iter().enumerate() {
        emit_scaffold(&mut out, i + 1, agg);
        out.push(String::new());
    }

    let n_policies = archetype.policies.len();
    for i in 0..n_policies {
        out.push(format!("  # policy {} — TODO: wire events to commands", i + 1));
    }
    if n_policies > 0 { out.push(String::new()); }

    if out.last().map(|l| l.is_empty()).unwrap_or(false) {
        out.pop();
    }
    out.push("end".into());
    out.join("\n")
}

/// Emit a scaffold aggregate — right shape, placeholder names.
fn emit_scaffold(out: &mut Vec<String>, index: usize, agg: &Aggregate) {
    let n_attrs = agg.attributes.len();
    let n_cmds = agg.commands.len();
    let n_vos = agg.value_objects.len();
    let has_lc = agg.lifecycle.is_some();

    out.push(format!("  aggregate \"Aggregate{}\", \"TODO\" do", index));

    for j in 0..n_attrs {
        out.push(format!("    attribute :field_{}, String", j + 1));
    }

    for j in 0..n_vos {
        out.push(format!("    value_object \"ValueObject{}\" do", j + 1));
        let vo_attrs = &agg.value_objects[j].attributes;
        for k in 0..vo_attrs.len() {
            out.push(format!("      attribute :field_{}, String", k + 1));
        }
        out.push("    end".into());
    }

    for j in 0..n_cmds {
        out.push(format!("    command \"DoThing{}\" do", j + 1));
        out.push("      role \"User\"".into());
        out.push("      description \"TODO\"".into());
        out.push(format!("      emits \"Thing{}Done\"", j + 1));
        out.push("    end".into());
    }

    if has_lc {
        out.push("    lifecycle :status, default: \"initial\" do".into());
        out.push("      # TODO: add transitions".into());
        out.push("    end".into());
    }

    out.push("  end".into());
}

/// Emit a single aggregate as bluebook DSL lines. Shared by generator and develop.
/// When scaffold=true, uses placeholder names. When false, copies archetype names.
pub fn emit_aggregate(out: &mut Vec<String>, agg: &Aggregate, _domain_name: &str) {
    emit_aggregate_impl(out, agg, _domain_name, false)
}

pub fn emit_scaffold_aggregate(out: &mut Vec<String>, agg: &Aggregate, domain_name: &str, index: usize) {
    emit_aggregate_impl(out, agg, domain_name, true)
}

fn emit_aggregate_impl(out: &mut Vec<String>, agg: &Aggregate, _domain_name: &str, scaffold: bool) {
    let name = if scaffold { format!("Aggregate{}", agg.name.len()) } else { agg.name.clone() };
    let desc = if scaffold { "TODO: describe this aggregate".to_string() } else { agg.description.as_deref().unwrap_or("TODO: describe this aggregate").to_string() };
    out.push(format!("  aggregate \"{}\", \"{}\" do", name, desc));

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
            // i106 dsl-mutation-primitives — multiply / clamp / decay.
            MutationOp::Multiply => format!("then_set :{}, multiply: {}", m.field, m.value),
            MutationOp::Clamp => format!("then_set :{}, clamp: {}", m.field, m.value),
            MutationOp::Decay => format!("then_set :{}, decay: {}", m.field, m.value),
            MutationOp::Delete => "then_delete".to_string(),
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
