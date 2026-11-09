# Runbook: the pipeline's CPU cost

**Status:** Current for local main at 6fd217b74 (2026-11-09), not yet pushed. The pipeline was paused when this
was written (`dispatch_roll_forward` false, board server stopped). Read "Turning the pipeline back on" before
changing that.

**Owner:** the person who turns the pipeline on. **Plan:** `~/.claude/plans/write-this-up-as-wondrous-babbage.md`
(items W0 to W18). **ADR:** [0201](../decisions/0201-a-resident-per-checkout-holds-the-described-domain-and-forks-a-launcher-line.md).

## Why

On 2026-11-09 the pipeline was running about 17,000 launcher boots a day (`~/.cache/hecks/usage.jsonl`). Each
boot is a fresh Ruby process that loads every bluebook, 2.8 s of CPU on main, and almost all of them then did 20 to
50 ms of work: about 12 CPU-hours a day before any spec run, Rust build or Claude session. The sources were the
board refreshing every 10 s through child launchers, every fill step booting a launcher, coders polling for
reviews, a hook booting a launcher on every Bash call, and a retry loop: three work items were started about 260
times a day each, because a refused dispatch yielded the item and the next fill picked it again. The caps let the
machine oversubscribe too: 14 sessions and a load limit of 16 on 12 cores.

## What changed

| Mechanism | Where | What it does |
|---|---|---|
| **Resident** | `lib/hecks/adapters/driving/resident/`, ADR 0201, `hecks.world` line `resident` | A launcher first asks its checkout's resident to run the line. The resident holds the loaded declarations and forks a child per line, so a warm line takes 0.2 to 0.3 s (2.8 s before). It retires when `lib/`, the lockfile or a loaded domain changes, after `idle_seconds` (600) idle, when its checkout or socket is gone, or when `max_residents` (8) others stand. |
| **Boot time** | `bluebook/dsl/word_gate.rb`, `validation/with_projections.rb`, `tools/project_cli/templates.rb` | The word gate answers from an index, the `with:` checks share one emitter index, IRB and OpenSSL load on first use, and the generated launcher sets up bootsnap when `CacheDir.stable?`. A cold boot after an edit under `lib/` is still about 9 s. |
| **Board in-process** | `pipeline_board/adapters/live_store.rb`, `board_restart.rb` | The board reads Work, runs and trains from its own booted domain, not child launchers; refresh is 30 s; it restarts itself above `rss_mb` or after `age_hours` (and not before 10 minutes up). |
| **Fill in-process** | `hecks/adapters/dispatching/in_process_runner.rb`, `filling.rb` | A fill's steps run in the filling process; a nested roll is refused while a confirmed fill runs. A cross-checkout fill still runs that checkout's launcher. |
| **Parking** | `dispatching/parking.rb`, Work fields `yield_kind`, `retry_at`, `yield_count` | A yielded item is not picked again at once. `transient` waits 5, 15, then 45 minutes; `missing_passage` waits 60; `already_recorded` waits until the run holding the key ends, and a fill retires a started run whose session is gone (`AgentRun.retire!`). `Dispatch.Preview` prints `<key> parked: <reason>`. |
| **Heartbeat rolls** | `hecks/delegate/delegate.bluebook` | A fill starts on: a machine state crossing a mark, a run ending, failing or being retired, work planned or reopened, a branch landed. A quiet beat starts nothing. Nothing rolls on a clock, so a parked item's `retry_at` passing does not start it by itself; the dispatcher fix that adds a `Dispatch.due` reading was still in review when this was written. |
| **Boot budget** | `tickets.world` `cpu_budget`, `hecks/adapters/boot_budget.rb` | Counts only usage rows with `boot_ms`, over a rolling 24 hours from `at`, read from the log's tail once per fill. A spent budget makes the plan start nothing ("skipped: boot budget spent"); `red-*` items are exempt. The board tile is "Boot hours today". Default 6.0 hours. |
| **Caps** | `tickets.world` `work_limit`, `dispatch_max_load`, `machine_marks` | 6 started items, fill stops at 1-minute load 8, Machine marks 6 and 8: one number, below the 12 cores, so the Machine pausing the plan and the plan's own check agree. |
| **Orphan reaper** | `agents/adapters/sweeping/orphans/` | The pruner's sweep stops an `exe/hecks` process older than 30 minutes whose parent is gone, and `hecks-isolated-push` spec leftovers older than a day. It keeps servers, `mcp`, `SendTrain`, ticks, gates, spec runs, landings and `Operation.run`/`follow` waits (`Rules::KEPT`), and spares Claude sessions and Cargo builds below a leftover. |
| **Cargo target** | `rust_build/session_build.rb`, `tickets.world` `session_environment` | A build that runs a produced binary gets its own directory under the shared root (`<name>-<8 hex>`); `cargo test` shares one. `nice` follows the workspace being built. |
| **Light MCP servers** | `adapters/driving/mcp/loading.rb`, `agents Role.server_env` | `hecks-mcp` and `hecks-query-ir` load the framework on the first tool call (16 MB idle, 48 MB after). A dispatched role session starts with `claude --mcp-config ... --strict-mcp-config` carrying the role's restricted server, which also leaves out MCP servers from other scopes. |
| **Coder waits** | `coder/coder.bluebook`, `Operation.follow` | A coder waits for its architect's verdict with `names.value=PlanReviewed,PlanReviewRecorded` in up to four 150 s calls, re-reading `PlanReview.reviews` after each. Specs are batched into one `run_spec_files!` call with `isolation.value=shared`. |

### The resident, in practice

- **See one:** `ps -Ao pid,rss,etime,command | grep resident/server.rb`. There is one per active checkout or worktree, about
  330 MB each.
- **Files:** `<cache>/resident/<8 hex of the checkout>.sock`, `.lock` and `.pid`, where `<cache>` is
  `HECKS_CACHE_DIR`, else `$XDG_CACHE_HOME/hecks` or `~/.cache/hecks`.
- **Stop one:** kill the process named in the `.pid` file. The next launcher line boots cold and starts another.
- **Turn it off for a line or a shell:** `HECKS_NO_RESIDENT=1`. `console`, `interview`, `init` and `mcp` and a
  `--stream` line never use it. Specs set it, so they cannot reach yours.
- **Served cold on purpose:** a line whose `HOME`, `XDG_CACHE_HOME`, `BUNDLE_GEMFILE`, `RUBYOPT`, `RUBYLIB`,
  `HECKS_NO_USAGE_CACHE` or `HECKS_ENGINE` differs from the resident's.

## Turning the pipeline back on

Nothing starts a session while `dispatch_roll_forward "Dispatch", roll_forward: false` stands in
`lib/hecks/hecks/tickets.world`. Check these first:

1. `uptime`: the 1-minute load should sit well under 8 on this 12-core machine.
2. `exe/hecks usage`: boots by caller and cold/warm counts. A caller with thousands of boots an hour is the next
   thing to fix, not the pipeline.
3. `exe/hecks Dispatch.Preview repo.value=$(pwd) budget_minutes.value=30`: what a fill would start, what is parked and
   why, and whether the budget refuses (`skipped: boot budget spent: <hours> of <budget>`).
4. `exe/hecks tickets Work.undone`: items stuck on a `reason` you recognise.
5. `exe/hecks RedFlag.status`: while main is red only `red-*` fixes start.

Then edit the line to `roll_forward: true` and land it through `Landing.land!` like any other change. Start the board
with `exe/hecks pipeline_board PipelineBoard.serve! run.value=<name> port.value=4747` (its refresh and restart
limits are the `board_restart` line of `lib/hecks/hecks/hecks.world`) and read the "Boot hours today" tile.

If the budget refuses, the day's measured boots are over `boot_hours_per_day`: find the caller with `exe/hecks usage`
before raising the number. A refusal never stops a `red-*` item.

## Diagnosing CPU

The usage log (`~/.cache/hecks/usage.jsonl`) has one JSON line per launcher run: `typed`, `resolved`, `status`, `ms`
(the command), `date`, `at`, `boot_ms` (process start to the command), `cold` (a bluebook had to be judged) and
`caller` (`HECKS_CALLER`, else `CLAUDE_SESSION_ID`). The event tap is `~/.claude/hecks-dev/events.jsonl`, one line per
event with `event`, `policy`, `command`, `outcome`, `at`.

| Symptom | Likely cause | Look with |
|---|---|---|
| Load high, many short `ruby` processes | launcher boots with no resident (`HECKS_NO_RESIDENT`, unstable cache dir, more than 8 checkouts) | `ps -Ao pid,etime,command \| grep -c 'exe/hecks'`; `exe/hecks usage` cold/warm |
| Same work id started again and again | a refusal that parks wrongly, or a run holding the key | count `WorkStarted` per id in the tap; `exe/hecks Dispatch.Preview` parked lines |
| Fill refuses with "boot budget spent" | measured boot hours over `cpu_budget` | `exe/hecks usage` by caller; the "Boot hours today" tile |
| Parked item never starts | a time-based park with no event to wake the roll | `exe/hecks Dispatch.Preview`; any planned item event rolls it |
| `rustc` at full CPU in a worktree | a build outside the dispatcher's environment | `ps -Ao pid,pcpu,command \| grep rustc`; `exe/hecks config domain.value=lib/hecks/hecks` |
| Many `claude`-owned `ruby` processes | two MCP servers per session | `ps -Ao rss,command \| grep -E 'tools/(mcp\|serve_query)'` |
| Board slow or memory growing | live store reload or restart limits | the `board_restart` line; `ps -o rss= -p <board pid>` |

## Known gaps

- **MCP forwarding is not built.** A server that has made a tool call holds the framework (48 MB); tool calls are not
  sent to the resident, by design (ADR 0201).
- **No prebuilt Rust kernel for macOS.** Only Linux host rows are published, so a worktree compiles its own binaries.
- **A coder's worktree has no local overlay.** `hecks.local.hecksagon` and `hecks.local.world` are gitignored, so
  stores that live there (Agents, Work) boot in Memory in a worktree, and the write guard refuses a write that would
  land there. The coder brief therefore runs its review commands and the red-flag follow through the main checkout:
  it names `{main}/exe/hecks` and `domain.value={main}/lib/hecks/hecks`, and the dispatcher fills `{main}` with the
  checkout the filling runs from (`BriefText#render(main:)`, which refuses a brief that names `{main}` unfilled).
  Other commands a session runs from its worktree that touch such a store still hit the guard.
- **Residents cost memory.** About 330 MB each, at most 8, one per checkout in use.
- **The reaper's `KEPT` list is by hand.** A new long-running verb needs adding to it.
- **`--strict-mcp-config` has not been run in a real session.**
