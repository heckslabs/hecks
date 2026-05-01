
    // `hecks-life run <file.bluebook> [key=val ...]`
    //
    // Script-mode execution: strip shebang, parse .bluebook + companion
    // .hecksagon, wire adapters, dispatch `entrypoint` with argv-bound
    // attrs. Exits 0/1/2/3/4 per hecks_life::run::ExitKind.
    //
    // The legacy interactive REPL that used to live under `run` now
    // lives under `hecks-life repl <file>` (below).
    if command == "run" {
        std::process::exit(hecks_life::run::run_script(&args));
    }
