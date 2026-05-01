    // Pipeline: givens → lifecycle check → mutations → lifecycle transition
    let cmd = cmd_for(rt, res);
    interpreter::check_givens(cmd, &state, &attrs)?;
    check_lifecycle(rt, res, &state)?;
    interpreter::apply_mutations(cmd, &mut state, &attrs);
    apply_lifecycle_transition(rt, res, &mut state);
