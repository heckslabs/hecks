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
            MutationOp::Remove => format!("then_set :{}, remove: {}", m.field, m.value),
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
