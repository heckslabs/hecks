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
| **Resident** | `lib/hecks/adapters/driving/resident/`, ADR 0201, `hecks.world` line `resident` | A launcher first asks its checkout's resident to run the line. The resident holds the loaded declarations and forks a child per line, so a warm line takes 0.2 to 0.3 s (2.8 s before). It retires when `lib/`, the lockfile or a loaded domain changes, after `idle_seconds` (600) idle, when its checkout or socket is gone, or when `max_residents` (8) others stand. It takes `workers` (8) callers at once, and a launcher waits `ready_wait_ms` (400) for its first word before it boots on its own. |
| **Boot time** | `bluebook/dsl/word_gate.rb`, `validation/with_projections.rb`, `tools/project_cli/templates.rb` | The word gate answers from an index, the `with:` checks share one emitter index, IRB and OpenSSL load on first use, and the generated launcher sets up bootsnap when `CacheDir.stable?`. A cold boot after an edit under `lib/` is still about 9 s. |
| **Board in-process** | `pipeline_board/adapters/live_store.rb`, `board_restart.rb` | The board reads Work, runs and trains from its own booted domain, not child launchers; refresh is 30 s; it restarts itself above `rss_mb` or after `age_hours` (and not before 10 minutes up). |
| **Fill in-process** | `hecks/adapters/dispatching/in_process_runner.rb`, `filling.rb` | A fill's steps run in the filling process; a nested roll is refused while a confirmed fill runs. A cross-checkout fill still runs that checkout's launcher. |
| **Parking** | `dispatching/parking.rb`, Work fields `yield_kind`, `retry_at`, `yield_count` | A yielded item is not picked again at once. `transient` waits 5, 15, then 45 minutes; `missing_passage` waits 60; `already_recorded` waits until the run holding the key ends, and a fill retires a started run whose session is gone (`AgentRun.retire!`). `Dispatch.Preview` prints `<key> parked: <reason>`. |
| **Heartbeat rolls** | `hecks/delegate/delegate.bluebook` | A fill starts on: a machine state crossing a mark, a run ending, failing or being retired, work planned or reopened, a branch landed. A quiet beat starts nothing. |
| **The clock's waker** | `dispatching/wake.rb`, `pending.rb`, `planned_cache.rb`, the `Wake` aggregate in `delegate.bluebook` | Each beat asks, in this process, whether the clock alone made something eligible, and rolls only if so: a parked item's `retry_at` passed; the boot budget could have freed (not read before the oldest counted boots leave the window, then every 10 minutes if the window alone cannot free it); the load fell under its limit, or a pause ended, after a fill was held back by it; a roll was refused while a fill ran. The planned items are kept 30 seconds; only a confirmed fill writes the flags, so a dry plan or the board cannot clear them. A vanished session is retired by the sweep once it has been started longer than `session_grace` (120 s) and `claude agents` does not list it, looked up at most once per 5 minutes while it stays listed. |
| **Boot budget** | `tickets.world` `cpu_budget`, `hecks/adapters/boot_budget.rb` | Counts only usage rows with `boot_ms`, over a rolling 24 hours from `at`, read from the log's tail once per fill. A spent budget makes the plan start nothing ("skipped: boot budget spent"); `red-*` items are exempt. The board tile is "Boot hours today". Default 6.0 hours. |
| **Caps** | `tickets.world` `work_limit`, `dispatch_max_load`, `machine_marks` | 6 started items, fill stops at 1-minute load 8, Machine marks 6 and 8: one number, below the 12 cores, so the Machine pausing the plan and the plan's own check agree. |
| **Orphan reaper** | `agents/adapters/sweeping/orphans/` | The pruner's sweep stops an `exe/hecks` process older than 30 minutes whose parent is gone, and `hecks-isolated-push` spec leftovers older than a day. It keeps servers, `mcp`, `SendTrain`, ticks, gates, spec runs, landings and `Operation.run`/`follow` waits (`Rules::KEPT`), and spares Claude sessions and Cargo builds below a leftover. |
| **Cargo target** | `rust_build/session_build.rb`, `tickets.world` `session_environment` | A build that runs a produced binary gets its own directory under the shared root (`<name>-<8 hex>`); `cargo test` shares one. `nice` follows the workspace being built. |
| **Rust build policy** | `rust_build/build_lock.rb`, `build_policy.rb`, `binary_cache.rb`, `tickets.world` `rust_build` | Every `cargo` or `rustc` hecks starts waits for one machine-wide lock (`~/.cache/hecks/rust-build/build.lock`, a `flock`, released when the holder exits), runs with `CARGO_BUILD_JOBS` from the line (4) and `nice` (15) in every checkout, and a native binary built from the same sources by another workspace is copied from `rust-build/bin/` instead of compiled. Skipped by `HECKS_NO_BUILD_LOCK=1` and in CI; a `CARGO_BUILD_JOBS` set by hand wins. A build started by hand is untouched. |
| **Light MCP servers** | `adapters/driving/mcp/loading.rb`, `mcp/roles.rb`, `role_server_cache.rb`, `agents Role.server_env` | `hecks-mcp` and `hecks-query-ir` load the framework on the first tool call (16 MB idle, 48 MB after). `hecks-mcp` narrows itself to its session's role from `CLAUDE_CODE_AGENT`, read from a cache file (`<cache>/role-servers`), so the narrowing holds on a resumed session; a session start passes no MCP flag. A role with rows and no named command serves no tool. |
| **Coder waits** | `coder/coder.bluebook`, `Operation.follow` | A coder waits for its architect's verdict with `names.value=PlanReviewed,PlanReviewRecorded` in up to four 150 s calls, re-reading `PlanReview.reviews` after each. Specs are batched into one `run_spec_files!` call with `isolation.value=shared`. |

### The resident, in practice

- **See one:** `ps -Ao pid,rss,etime,command | grep resident/server.rb`. There is one per active checkout or worktree, about
  330 MB each.
- **Files:** `<cache>/resident/<8 hex of the checkout>-p<protocol>.sock`, `.lock`, `.pid` and `.version`, where
  `<cache>` is `HECKS_CACHE_DIR`, else `$XDG_CACHE_HOME/hecks` or `~/.cache/hecks`. The protocol is in the name, so a
  landing that changes how launcher and resident talk starts new residents; the old ones, which no launcher
  reaches, exit when idle.
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
(the command), `date`, `at`, `boot_ms` (process start to the command), `cold` (a bluebook had to be judged; never
true for a line a resident served), `caller` (`HECKS_CALLER`, else `CLAUDE_SESSION_ID`; sessions are named
`role:run`, the board `board`, the guard hook `hook:orchestrator_guard`) and `resident` (how the line met the
resident: `served`, `none`, `started`, `bypass`, `unstable` or `refused:<reason>`, with reasons `stale`, `env`,
`changed`, `script`, `busy`, `dropped`, `unsafe`, `path`, `crowded` and `protocol`). `exe/hecks usage` sums the outcomes, the
share served, the refusal reasons and the last hour's boots per caller. The event tap is `~/.claude/hecks-dev/events.jsonl`, one line per
event with `event`, `policy`, `command`, `outcome`, `at`.

Shared caches and records, which every checkout and worktree reads, and how each is kept:

- **Usage log:** above 16 MB, runs older than 30 days move to `usage-YYYYMM.jsonl.gz` beside it and the
  rest stay; the budget reads only a bounded tail. A run with no `at` is priced only when dated today.
- **Verdict cache** (`hecks_verdict_cache/`): a file is marked used when read, so a checkout that only reads keeps
  its file; other code's files go after a day unused, and no more than eight are kept. Writers merge under a lock.
- **Gate memo** (`~/.claude/hecks-dev/gate_memo.json`): each check keeps its newest four green runs, so checkouts on
  different trees do not evict one another; a red run forgets only the runs on its own inputs.
- **MCP guides:** entries unread for 30 days go, and at most 200 are kept. **Resident files:** a lock file no
  resident has taken for a day, with no socket beside it, is removed when a resident starts.
- **Not pruned:** bootsnap's cache (it has no eviction; delete `~/.cache/hecks/bootsnap` when it grows) and the
  shared SQLite stores.

| Symptom | Likely cause | Look with |
|---|---|---|
| Load high, many short `ruby` processes | launcher boots with no resident (`HECKS_NO_RESIDENT`, unstable cache dir, more than 8 checkouts) | `ps -Ao pid,etime,command \| grep -c 'exe/hecks'`; `exe/hecks usage` cold/warm |
| Same work id started again and again | a refusal that parks wrongly, or a run holding the key | count `WorkStarted` per id in the tap; `exe/hecks Dispatch.Preview` parked lines |
| Every line `refused:busy`, about 1.8 s, right after a landing | a resident of the old protocol that no launcher can talk to (fixed: the protocol is in the file names, and a launcher stops a resident that is busy twice in a row); the `resident` field shows `refused:protocol` while an old one stands | `ps -Ao pid,etime,command \| grep resident/server.rb`; kill the old one if it must go at once; `exe/hecks usage` resident section |
| `refused:env:<NAME>` on an ordinary caller, about 1.4 s a line | the resident was born from an odd environment (an older one, started by a spec harness or a hook); a resident now starts with a plain environment whoever starts it, and `<NAME>` is the first variable the caller differs on; three such refusals in a minute stop a resident that was not born plain | `exe/hecks usage` (resident section, refusal reasons); `cat ~/.cache/hecks/resident/*.baseline` (empty means plain); kill the old resident if it must go at once |
| Few lines served by the resident | the `resident` field says why: `refused:changed` (code edits retire it), `refused:env:<NAME>`, `refused:busy` (no first word within `ready_wait_ms`), `refused:dropped:deadline` (the caller took over five seconds) or `refused:dropped:closed` (the resident hung up), `none`/`started` (no resident yet; one launcher starts it, the rest boot at once), `unstable` or `refused:crowded` | `exe/hecks usage` resident section (outcomes, share served, refusal reasons) |
| A served line takes over 0.15 s | the phases of the line, from the shell to its end: the rbenv shim and rubygems cost about 60 ms before the launcher's first line, the child's boot and the query the rest | `HECKS_TRACE_TIMING=1 exe/hecks <line>` prints `TRACE <phase> <wall ms>` on standard error from the launcher and the child (ADR 0201, "The warm path"); a question not under `reads_tap` in `hecks.world` also opens every bound store |
| Fill refuses with "boot budget spent" | measured boot hours over `cpu_budget` | `exe/hecks usage` by caller; the "Boot hours today" tile |
| Parked item never starts | its retry time has not passed, the machine is over its limit, or roll-forward is false | `exe/hecks Dispatch.Preview` (parked and skipped lines); `dispatch_roll_forward` in `tickets.world`; the waker rolls when the time passes or the load clears |
| A run stays started after its session was removed | the sweep waits out `session_grace` and the 5-minute look-up throttle | `claude agents --json --all`; `exe/hecks AgentRun.retire! to=<run>` after the grace |
| `rustc` at full CPU in a worktree | a build outside the dispatcher's environment | `ps -Ao pid,pcpu,command \| grep rustc`; `exe/hecks config domain.value=lib/hecks/hecks` |
| Several `rustc` at once, or a build that seems stuck | builds started by hand skip the lock; a hecks build waits behind another (it says so after 5 s) | `cat ~/.cache/hecks/rust-build/build.lock` names the holder's pid; `HECKS_NO_BUILD_LOCK=1` skips the wait; ADR 0203 has the build timings |
| Many `claude`-owned `ruby` processes | two MCP servers per session | `ps -Ao rss,command \| grep -E 'tools/(mcp\|serve_query)'` |
| Board slow or memory growing | live store reload or restart limits | the `board_restart` line; `ps -o rss= -p <board pid>` |
| A refusal that names a `save_saga` or outbox warning | the warning is a boot notice, not the cause; the cause is the first line of the refusal and the notices follow `-- boot notices --` | read the refusal's first line; `Hecks::BootNotices` lists the notices |

## Known gaps

- **MCP forwarding is not built.** A server that has made a tool call holds the framework (48 MB); tool calls are not
  sent to the resident, by design (ADR 0201).
- **No prebuilt Rust kernel for macOS.** Only Linux host rows are published, so a worktree compiles its own binaries.
  The binary cache covers a worktree whose `rust/` is unchanged.
- **A worktree's host build compiles its 402 registry packages again.** A binary build takes a directory of its own,
  so `rust/host` (wasmtime and the rest) is not shared between worktrees; `sccache` would share it (not installed).
  ADR 0203 has the measurements and why the kernel split was not made.
- **A coder's worktree has no local overlay.** `hecks.local.hecksagon` and `hecks.local.world` are gitignored, so
  stores that live there (Agents, Work, Landing, AgentRun and the rest of the shared ledgers) boot in Memory in a
  worktree. A command that **writes** one is run in the main checkout instead (`LedgerForward`, ADR 0202), with the
  same arguments and a `checkout.value` naming the worktree when the command takes one. `HECKS_NO_FORWARD=1` refuses it
  instead, naming the main checkout to run it from. **Reads are not forwarded:** a query of such a store from a
  worktree reads the worktree's empty Memory. The coder brief therefore runs its review commands and the red-flag
  follow through the main checkout: it names `{main}/exe/hecks` and `domain.value={main}/lib/hecks/hecks`, and the
  dispatcher fills `{main}` with the checkout the filling runs from (`BriefText#render(main:)`, which refuses a brief
  that names `{main}` unfilled).
- **Residents cost memory.** About 330 MB each, at most 8, one per checkout in use.
- **The reaper's `KEPT` list is by hand.** A new long-running verb needs adding to it.
- **The orchestrator cannot reach MCP tools.** Its `tools: Bash` frontmatter hides them (tested live, 2026-11-09: the
  session's tools were `["Bash"]` with both servers connected), so its restricted server matters only if
  `mcp__hecks-mcp__*` is added to that list. A resumed session no longer loses the restriction, because the server
  reads it from the environment, but this has been shown for a fresh session with an inline agent, not for a resumed one.
