    let producible = collect_producible_states(agg);

    for cmd in &agg.commands {
        for given in &cmd.givens {
            let Some((field, value)) = parse_equality(&given.expression) else { continue };
            // Lifecycle defaults satisfy themselves.
            if let Some(lc) = &agg.lifecycle {
                if lc.field == field && lc.default == value { continue; }
            }
            if !producible.contains(&(field.clone(), value.clone())) {
                out.push(Finding::err(
                    format!("{}.{}", agg.name, cmd.name),
                    format!(
                        "given `{} == {:?}` is unreachable — no command \
                         sets {} to {:?} and no lifecycle transition \
                         produces it",
                        field, value, field, value,
                    ),
                ));
            }
        }
    }
