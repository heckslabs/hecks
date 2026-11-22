# One control process serves control commands from any worktree

**Status:** Accepted. Date: 2026-11-21. The architect reviewed the plan (verdict sound with changes, all taken).
Builds on [0201](0201-a-resident-per-checkout-holds-the-described-domain-and-forks-a-launcher-line.md), which keeps
its decision to fork per line (threads were rejected), and takes the first step of
[0234](0234-a-command-starts-no-process.md).

## Context

A control command acts on shared stores (work items, messages, the dial, the red flag). Until now each worktree asked
its own resident first, and only then the primary's. A worktree's resident idles out after 120 seconds, so most of
those lines started cold, and a caller whose `GEM_HOME` or `BUNDLE_GEMFILE` differed was refused as `env:` and also
ran cold.

## Decision

1. **The control process is the primary checkout's resident, started with `--control`.** It never idles out and is not
   counted against `max_residents`. launchd keeps it (`dev.hecks.control-process`, `KeepAlive`), as it keeps the Claude
   daemon; `ControlProcessSchedule` writes the job. It still forks per line.
2. **A control line from any checkout goes straight to it.** A worktree's own resident is not asked and none is
   started for a control line. With the control process down the line starts cold and says
   `hecks: control process down, running cold` on stderr; `Stuck` records why as before.
3. **It takes a control line whatever gem environment the caller carries** (`GEM_HOME`, `GEM_PATH`, `BUNDLE_GEMFILE`,
   `RUBYOPT`, `RUBYLIB`), and does not refuse for local files in the caller's directory: the line acts on the primary's
   stores, with the primary's code. Every other line is judged as 0201 says.
4. **The control words name only aggregates on shared stores:** `work message dial redflag`. `Landing`, `Integration`
   and `AgentRun` act on a worktree's branch and checkout, and a landing of a bluebook change must not run on the
   primary's older code, so they stay out.
5. **Reads fork too.** Answering a read in the process would be a thread's work, which 0201 rejected.

## Consequences

- When the code changes the control process retires and launchd restarts it; lines in the gap run cold.
- Not built here: a cap of two cold starts at once, a count of fallbacks that raises a stall row, and the world line
  for `control_process_job`. The count has no home until a persisted aggregate or a port reads it (a cold boot's
  Memory store cannot add up across boots), so it stays for 0234's counting step.
