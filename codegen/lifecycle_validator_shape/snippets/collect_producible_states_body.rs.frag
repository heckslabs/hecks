    let mut produced: BTreeSet<(String, String)> = BTreeSet::new();
    // From every aggregate attribute's `default:` value. The runtime
    // initializes the field to that default on every fresh aggregate,
    // so the state is reachable without any command needing to produce it.
    for attr in &agg.attributes {
        if let Some(d) = &attr.default {
            let val = d.trim_matches('"').to_string();
            if !val.is_empty() {
                produced.insert((attr.name.clone(), val));
            }
        }
    }
    // From every command's then_set Set mutations.
    for cmd in &agg.commands {
        for m in &cmd.mutations {
            if let MutationOp::Set = m.operation {
                let val = m.value.trim_matches('"').to_string();
                produced.insert((m.field.clone(), val));
            }
        }
    }
    // From every lifecycle transition's to_state.
    if let Some(lc) = &agg.lifecycle {
        for t in &lc.transitions {
            produced.insert((lc.field.clone(), t.to_state.clone()));
        }
    }
    produced
