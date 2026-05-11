
    // `storehouse statusline` — Statusline capability runner (i97
    // → i145). Fires the bluebook-declared rendering of Miette's
    // one-line body status. Replaces statusline-command.sh's 273-
    // line shell with a Rust mirror of run_status/ : reads body
    // heki, branches on consciousness state, prints a single line.
    // Same family as run_status / run_loop / run_daemon — kernel-
    // surface CLI primitive a bluebook capability dispatches into.
    // Bluebook brain stays in capabilities/statusline/.
    if command == "statusline" {
        storehouse::run_statusline::run();
        return;
    }
