
    // `hecks-life daemon <ensure|status|stop> <pidfile> [command...]`
    //
    // Process-lifecycle primitive — the runtime gap that kept boot_miette
    // in shell. `ensure <pidfile> <cmd> [args]` reads the pidfile, returns
    // alive if the PID is still running (idempotent boot), otherwise spawns
    // the command detached (setsid + null stdio) and writes the new PID.
    // No wrapping subshells, no PPID=1 orphan launchers — the leak that
    // accumulated five ghost shells over today's session is structurally
    // closed. Sibling of the cadence-loop primitive (`hecks-life loop`) ;
    // together they let bluebook capabilities declare daemon lifecycles
    // without reaching for shell. boot_miette.sh's `( cd "$DIR" && nohup
    // ./script & )` pattern retires once it migrates to this primitive.
    if command == "daemon" {
        run_daemon(&args);
        return;
    }
