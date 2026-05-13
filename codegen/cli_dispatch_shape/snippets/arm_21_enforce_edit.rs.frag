
    // `storehouse macrophage` — PostToolUse listener primitive.
    // (Old name `storehouse enforce-edit` kept as deprecated alias.)
    //
    // Reads tool-input JSON from stdin, classifies the touched file
    // by extension, dispatches Macrophage.RecordXxxEdit (and, for
    // imperative-language files, Macrophage.Complain), prints the
    // complaint to stderr, exits 2 so Claude Code routes the
    // complaint to the agent as a system reminder.
    //
    // Closes the runtime gap (i104) that previously forced
    // enforce_bluebook.sh to exist — Claude Code's PostToolUse hook
    // contract takes a command, and the command can now be storehouse
    // directly. No shell glue. Same family as `storehouse loop` and
    // `storehouse daemon` — kernel-surface primitives a bluebook
    // capability dispatches into. The Macrophage brain stays in
    // aggregates/discipline/macrophage/macrophage.bluebook (i553).
    if command == "enforce-edit" || command == "macrophage" {
        // Deprecation notice if old form used. Print BEFORE the dispatch
        // because run_macrophage exits internally (never returns).
        if command == "enforce-edit" {
            eprintln!("[macrophage] note : `storehouse enforce-edit` renamed to `storehouse macrophage` (i553) ; old form still works for now.");
        }
        run_macrophage(&args);
        return;
    }
