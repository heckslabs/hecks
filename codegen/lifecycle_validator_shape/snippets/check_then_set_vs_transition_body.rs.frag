        for cmd in &agg.commands {
            let targets: BTreeSet<&str> = lc.transitions.iter()
                .filter(|t| t.command == cmd.name)
                .map(|t| t.to_state.as_str())
                .collect();
            for m in &cmd.mutations {
                if !matches!(m.operation, MutationOp::Set) { continue; }
                if m.field != lc.field { continue; }
                let value = m.value.trim_matches('"');
                if value.starts_with(':') { continue; }
                if targets.is_empty() {
                    out.push(Finding::warn(
                        format!("{}.{}", agg.name, cmd.name),
                        format!(
                            "then_set :{} => {:?} sets the lifecycle field but the \
                             command declares no transition — it bypasses the state \
                             machine (no from-guard, invisible to the lifecycle map). \
                             Express it as a transition so the state change is named, \
                             guarded, and visible.",
                            m.field, value,
                        ),
                    ));
                } else if !targets.contains(value) {
                    out.push(Finding::err(
                        format!("{}.{}", agg.name, cmd.name),
                        format!(
                            "then_set :{} => {:?} disagrees with the command's lifecycle \
                             transition target(s) {:?} — the transition runs after \
                             mutations and overrides, so this then_set never takes \
                             effect. Align them or drop the then_set.",
                            m.field, value, targets,
                        ),
                    ));
                }
            }
        }
