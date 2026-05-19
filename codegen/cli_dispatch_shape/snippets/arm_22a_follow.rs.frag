
    // `storehouse follow [stream]` — tail the storehouse bus log
    // from another terminal. Reads the same file the runtime's
    // `storehouse_log` writer appends to (default
    // `<miette-state>/information/storehouse.log` or whatever
    // `$STOREHOUSE_LOG_FILE` overrides it to). Filter forms : `all`
    // (default), `dispatch` / `event` / `cascade` / `policy` for one
    // of the four surfaces, or any other substring for a contains-
    // match (e.g. `follow ShellTool`, `follow Tools::EmailTool`).
    // Polls every 100 ms ; SIGINT exits cleanly. Same kernel-surface
    // family as `storehouse statusline` — paired with the
    // `runtime::storehouse_log` writer that lives in i622.
    if command == "follow" {
        std::process::exit(storehouse::run_follow::run(&args));
    }
