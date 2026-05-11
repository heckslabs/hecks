
    if command == "behaviors" {
        // i500 — alias for `test`. Stays one release, then collapses.
        run_behaviors(&args);
        return;
    }
