
    // `storehouse loop <agg-dir-or-bluebook> <Aggregate.Command> --every <duration> [key=val ...]`
    //
    // Cadence-loop primitive (i76). Boots the runtime once and dispatches
    // the named command at the given cadence in a tight loop, no shell
    // wrapper required. Replaces the `while true; do ...; sleep N; done`
    // pattern that body daemons (heart, breath, circadian, ultradian,
    // mindstream, sleep_cycle) currently use, where each iteration paid
    // a full runtime-boot cost.
    //
    // Duration accepts "1s", "500ms", "2m" — anything parsed by
    // parse_loop_duration. SIGINT / SIGTERM exits cleanly.
    //
    // [TRANSITIONAL] Like the speak/status/musings/boot/daemon wrappers
    // above, this hardcoded route is itself a bluebook smell — adding it
    // to main.rs is exactly what i80 (CLI routing as bluebook) names as
    // the wrong layer. Kept here only until i80's cli.bluebook lands and
    // every CLI subcommand becomes a declared route, at which point this
    // function retires alongside the others. See i80 for the retirement
    // contract.
    if command == "loop" {
        run_loop(&args);
        return;
    }
