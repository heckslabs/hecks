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

pub fn emit_scaffold_aggregate(out: &mut Vec<String>, agg: &Aggregate, domain_name: &str, _index: usize) {
    emit_aggregate_impl(out, agg, domain_name, true)
}

