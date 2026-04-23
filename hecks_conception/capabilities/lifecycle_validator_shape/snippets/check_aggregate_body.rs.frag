    // Reachable states: the lifecycle default plus every transition's
    // to_state. Anything outside this set is unreachable, so a
    // transition with `from:` pointing outside it is dead code.
    let mut reachable: BTreeSet<String> = BTreeSet::new();
    if !lc.default.is_empty() {
        reachable.insert(lc.default.clone());
    }
    for t in &lc.transitions {
        reachable.insert(t.to_state.clone());
    }

    for t in &lc.transitions {
        if let Some(from) = &t.from_state {
            if !reachable.contains(from) {
                out.push(Finding::err(
                    format!("{}.{}", agg.name, t.command),
                    format!(
                        "transition's from: {:?} is unreachable — \
                         the {:?} field can only be {} \
                         (default {:?} + transition to_states), so this \
                         transition can never fire",
                        from, lc.field,
                        format_set(&reachable),
                        lc.default,
                    ),
                ));
            }
        }
    }

    // Stuck-default warning: if the lifecycle has transitions but none
    // can fire when the field is at its default value, the aggregate
    // is permanently stuck in default. (Transitions with from_state =
    // None fire from any state including default.)
    if !lc.transitions.is_empty() {
        let any_fires_from_default = lc.transitions.iter().any(|t| match &t.from_state {
            None => true,
            Some(from) => from == &lc.default,
        });
        if !any_fires_from_default {
            out.push(Finding::warn(
                format!("{}.lifecycle({})", agg.name, lc.field),
                format!(
                    "no transition can fire from the default state {:?} — \
                     fresh aggregates will be stuck forever",
                    lc.default,
                ),
            ));
        }
    }
