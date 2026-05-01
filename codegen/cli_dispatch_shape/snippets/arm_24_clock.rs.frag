
    // `hecks-life clock <agg-dir> --segment <hour-range>:<Cmd> [...] [--poll <dur>]`
    //
    // Wall-clock segment trigger primitive (i107). Boots the runtime
    // once, then on each poll tick (default 60s) computes the current
    // local-hour segment and dispatches the matching command IFF the
    // segment changed since the last tick. Replaces circadian.sh.
    //
    // Same family as `hecks-life loop` and `hecks-life daemon` —
    // kernel-surface primitive a bluebook circadian capability
    // dispatches into. Same i80 retirement contract.
    if command == "clock" {
        run_clock(&args);
        return;
    }
