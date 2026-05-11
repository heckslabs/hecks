
    // `storehouse run <file.bluebook> [key=val ...]`
    //
    // Script-mode execution: strip shebang, parse .bluebook + companion
    // .hecksagon, wire adapters, dispatch `entrypoint` with argv-bound
    // attrs. Exits 0/1/2/3/4 per storehouse::run::ExitKind.
    //
    // The legacy interactive REPL that used to live under `run` now
    // lives under `storehouse repl <file>` (below).
    if command == "run" {
        std::process::exit(storehouse::run::run_script(&args));
    }
