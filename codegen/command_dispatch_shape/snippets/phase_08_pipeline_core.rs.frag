    // Pipeline: givens → lifecycle check → mutations → lifecycle transition
    let cmd = cmd_for(rt, res);
    interpreter::check_givens(cmd, &state, &attrs)?;
    check_lifecycle(rt, res, &state)?;
    interpreter::apply_mutations(cmd, &mut state, &attrs);
    apply_lifecycle_transition(rt, res, &mut state);

    // f4 — aggregate-level invariants are checked on the RESULTING state
    // (post-mutation, post-transition) before save. A violated invariant
    // rejects the command exactly like a failed `given` : 0 events, no save.
    // An invariant is a `given` enforced on every command.
    if let Some(violated) = crate::invariants::check_invariants(
        &rt.domain.aggregates[agg_idx].invariants,
        &state,
        &attrs,
    ) {
        return Err(RuntimeError::InvariantViolation {
            name: violated.name.clone(),
            expression: violated.expression.clone(),
        });
    }
