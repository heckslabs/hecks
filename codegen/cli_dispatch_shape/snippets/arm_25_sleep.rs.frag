
    // `storehouse sleep` — blocking streaming-sleep CLI (i113).
    //
    // Dispatches Consciousness.EnterSleep (skipping if state is already
    // "sleeping" — mid-flight join), then polls consciousness.heki /
    // dream_state.heki / lucid_dream.heki at 1Hz, emitting one streaming
    // line per state change. Breaks when state != "sleeping", waits
    // briefly for /tmp/wake_review_latest.md (the wake hook fires
    // wake_review.sh + interpret_dream.sh automatically), prints it to
    // stdout, exits 0.
    //
    // Same family as run_loop / run_daemon / run_enforce_edit / run_clock
    // — kernel-surface CLI primitive. Bluebook brain (sleep.bluebook,
    // lucid_dream.bluebook) stays unchanged ; this just wires the
    // dispatch + heki polling + dream stream + wake-report read into a
    // single blocking command.
    if command == "sleep" {
        run_sleep(&args);
        return;
    }
