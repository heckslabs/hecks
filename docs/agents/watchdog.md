# The watchdog

A launchd job (`dev.hecks.watchdog`, KeepAlive, normal priority) keeps the pinned sessions working. It runs
apart from Hecks and Claude and boots no domain.

- **Declared in the bluebook.** `lib/hecks/hecks/watchdog/watchdog.bluebook`: the `PinnedSession` rows (name,
  directory), their `WatchedLoop` rows (crons, monitors, watches) and the `Setting` numbers the loop compares.
  No session id is declared: a resumed session takes a new one, so the loop finds each by its listed name.
- **Armed by a verb.** `exe/hecks Watchdog.arm! run.value=<name> confirm.value=true --wait` writes the job and the
  roster; without `confirm` it says what it would write. `Watchdog.disarm!` removes it. Only the owner or the lead arms it.
- **Each pass (30 s).** Bring the Claude daemon up if it is gone; then resume each pinned session `claude agents`
  lists as gone (`claude --bg --resume <id> -n <name>`, from its directory); then check that a resumed
  session's start hook ran (`armed/<name>` stamp newer than the resume). It never signals a process.
- **Loops.** The SessionStart hook (`.claude/hooks/session_loops.sh`) names a pinned session's loops, read from
  `~/.claude/hecks-dev/watchdog/loops.json`, and leaves the stamp.
- **Journal.** `~/.claude/hecks-dev/watchdog/journal.jsonl`: `resumed`, `loops_armed`, `loops_missing`,
  `daemon_started`, `held_on_efficiency_cores`, and `mass_kill` (pinned sessions gone within the declared window, with a
  `ps` snapshot). Recording these into the domain and notifying the owner is a later slice.
