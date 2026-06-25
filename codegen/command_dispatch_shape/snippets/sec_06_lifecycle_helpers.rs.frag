/// Verify the command is allowed given the current lifecycle state.
/// Routes through Resolution so entity commands consult the entity's
/// lifecycle when present (falls back to the parent aggregate's
/// lifecycle otherwise).
fn check_lifecycle(
    rt: &Runtime, res: Resolution, state: &AggregateState,
) -> Result<(), RuntimeError> {
    let lifecycle = match lifecycle_for(rt, res) {
        Some(lc) => lc,
        None => return Ok(()),
    };
    let cmd = cmd_for(rt, res);
    let matching: Vec<_> = lifecycle.transitions.iter()
        .filter(|t| t.command == cmd.name).collect();
    if matching.is_empty() { return Ok(()); }

    let current = format!("{}", state.get(&lifecycle.field));
    let allowed = matching.iter().any(|t| match &t.from_state {
        Some(from) => current == *from,
        None => true,
    });
    if allowed { Ok(()) } else {
        Err(RuntimeError::LifecycleViolation {
            command: cmd.name.clone(),
            field: lifecycle.field.clone(),
            current,
            allowed: matching.iter().filter_map(|t| t.from_state.clone()).collect(),
        })
    }
}

/// Apply the lifecycle transition if one matches the resolved command.
/// Resolution-aware (i111-J) — entity commands consult the entity's
/// lifecycle when present, otherwise the parent aggregate's.
fn apply_lifecycle_transition(rt: &Runtime, res: Resolution, state: &mut AggregateState) {
    let lifecycle = match lifecycle_for(rt, res) {
        Some(lc) => lc,
        None => return,
    };
    let cmd = cmd_for(rt, res);
    let current = format!("{}", state.get(&lifecycle.field));
    for t in &lifecycle.transitions {
        if t.command != cmd.name { continue; }
        let from_ok = match &t.from_state {
            Some(from) => current == *from,
            None => true,
        };
        if from_ok {
            state.set(&lifecycle.field, Value::Str(t.to_state.clone()));
            return;
        }
    }
}

