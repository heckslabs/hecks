
    // `hecks-life enforce-edit` — PostToolUse listener primitive.
    //
    // Reads tool-input JSON from stdin, classifies the touched file
    // by extension, dispatches Enforcer.RecordXxxEdit (and, for
    // imperative-language files, Enforcer.Complain), prints the
    // complaint to stderr, exits 2 so Claude Code routes the
    // complaint to the agent as a system reminder.
    //
    // Closes the runtime gap (i104) that previously forced
    // enforce_bluebook.sh to exist — Claude Code's PostToolUse hook
    // contract takes a command, and the command can now be hecks-life
    // directly. No shell glue. Same family as `hecks-life loop` and
    // `hecks-life daemon` — kernel-surface primitives a bluebook
    // capability dispatches into. The Enforcer brain stays in
    // aggregates/enforcer.bluebook.
    if command == "enforce-edit" {
        run_enforce_edit(&args);
        return;
    }
