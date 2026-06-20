# SPEC — live interval scheduling (the first real scheduler)

VOICE : I / my / mine. A design handoff to a FRESH HEAD. This is kernel-floor +
parity work and the firing semantics are design judgment parity cannot verify, so
it is gated behind this spec (advisor, 2026-06-20) and must be built on a fresh,
low-context head in a gated worktree — NOT in the high-context session that wrote
this. The decision is made (Chris) ; what remains is building it right.

## The decision (Chris, 2026-06-20)
`driving on interval "2s"` must give LIVE interval scheduling — a real scheduler
with per-handler last-fired tracking and a single-owner firing model so a handler
fires ONCE (not N×) in a live daemon. NOT test-only parity. NOT the Driver
aggregate (Chris : "i don't want a driver that's for sure" — the schedule lives on
the hecksagon `driving on` adapter, never a Driver domain root).

## The finding that reframes everything (verified 2026-06-20)
`driving on cron` handlers DO NOT FIRE IN ANY LIVE DAEMON today. `fire_driving_cron_ticks`
has exactly two callers :
  - `behaviors_runner.rs:459` — the TEST path.
  - `loop_driver.rs:283` — inside `LoopDriver::tick_once` (the `storehouse run-loop` daemon).
The live Procfile runs 7× `storehouse loop`, 1× `clock`, 1× `run` (boot), 1×
`serve-socket`, and ZERO `storehouse run-loop`. `run_loop` (the live `storehouse
loop` path, main.rs:5212) is a plain `loop { rt.dispatch(cmd); sleep(every) }` — it
NEVER calls fire_driving_cron_ticks. So LoopDriver runs nowhere in production, and
`driving on cron` is, live, test-only grammar. The Pizzas/agent_inbox `driving on
cron` exemplars are behaviors-green decorations that never fire live.

Corollary : "add interval symmetric with cron" would inherit cron's test-only
status — it would parse + test-fire + project, but fire in NO live daemon. That is
why Chris chose the real scheduler instead.

## The system's REAL live cadence (today)
The dedicated `storehouse loop <root> <Cmd> --every Ns` process : one OS process,
one cadence, one (or comma-rotated) command, OS-sleep timing. heart 1s, breath
4.5s (Inhale,Exhale rotation), inbox 900s, process_macrophage 30s, conductor_sweep
60s, speech_stream 200ms. This is process-per-cadence — the cadence IS the process's
whole identity. It is correct and single-owner BY CONSTRUCTION (one process each).
It is NOT a driving handler and does not scan hecksagons.

## The double-fire hazard (advisor #3 — verified, structural)
`run_loop` loads ALL hecksagons under its root (`load_all_hecksagons(target)`,
main.rs ~5328). Three daemons run `storehouse loop aggregates …` (inbox,
process_macrophage, conductor_sweep). So IF driving-firing were added to run_loop,
EVERY driving handler under aggregates/ would fire 3× — a bug introduced, not
pre-existing. The live loop therefore CANNOT host driving-handler firing. This is
the constraint that picks the design.

## THE DESIGN — a dedicated scheduler daemon
Add ONE new daemon : `storehouse drive <root> [--poll <dur>]`. Single-owner by
Procfile presence (exactly one `drive` line). It is the SOLE process that fires
`driving on` handlers — cron, interval, and (future) clock all unified through it.
The 7 `storehouse loop` daemons are UNTOUCHED and continue NOT firing driving
handlers.

  - Loads all hecksagons under <root> (like run_loop).
  - Holds in-memory `HashMap<HandlerId, last_fired: Instant>`.
  - Every poll tick (default --poll 1s), for each driving handler, fire if DUE :
      interval "Ns" : due if last_fired is None (first tick → fire immediately)
                      OR now - last_fired >= N. Set last_fired = now on fire.
      cron "expr"   : due if the 5-field expr matches the current wall-clock
                      minute AND not already fired this minute. (Today cron does
                      NOT evaluate the expr — every tick fires every handler. The
                      scheduler is where real cron-expr matching finally lands ;
                      scope it as a sibling follow-on if it bloats this card.)
      clock segment : due if current hour ∈ the dispatch's `when` hour-range.
  - Fire via `command_dispatch::dispatch_cascade` (same path the resolver uses
    today) so emits reach the bus and downstream `driven on` chains fire.

### Advisor's three questions, answered
1. WHERE does last-fired-at live (no Driver aggregate)? In-memory in the `drive`
   daemon, keyed by HandlerId = stable composite of (hecksagon adapter name, kind,
   arg, dispatch command FQN). On RESTART : in-memory map resets → each handler is
   due on the first poll tick → fires once early. Acceptable because driving
   handlers are idempotent sweeps (ExpireStale, Poll). DOCUMENT this early-fire.
2. WHAT binds `interval "2s"` to the host's cadence? The `--poll` resolution. A
   handler cannot fire faster than the poll. CONSTRAINT : interval >= poll ;
   interval values round UP to poll multiples. Default poll 1s ; nothing live needs
   sub-second driving (speech_stream 200ms stays a dedicated --every loop, not a
   driving handler). Optionally the daemon sleeps adaptively to the min interval.
3. The DOUBLE-FIRE : solved by single-owner. Only one `drive` daemon exists, so a
   handler fires once. The loop daemons do not fire driving handlers at all.

### Relationship to the existing --every loops
Leave them AS-IS. Two clearly-separated mechanisms :
  - `storehouse loop … --every Ns` = "this PROCESS dispatches command X every N"
    (cadence is the process's identity).
  - `driving on interval` fired by `storehouse drive` = "this aggregate has a clock
    EDGE that fires command Y every N" (declarative ; the scheduler fires it).
A later migration COULD re-express the --every loops as `driving on interval`
handlers under one `drive` daemon, retiring the hand-authored Procfile lines — but
that is a separate card, not this one.

### No-Driver-aggregate vs scheduler-daemon — reconciled
"No Driver" = no Driver DOMAIN AGGREGATE (no bluebook root with Schedule/Dispatch
VOs ; retire driving.bluebook's Driver chapter — confirm DELETE vs leave-unused
with Chris first, don't fold uninvited). The `storehouse drive` SCHEDULER is
runtime machinery (a daemon), NOT a domain concept — these do not conflict.

## THE PARITY-SAFE SLICE (lands first, independently, safe in any session)
The Rust hecksagon parser is already KIND-AGNOSTIC : `parse_driving_handler` reads
the kind as the first token after `driving on`, so `driving on interval "2s"`
already parses on the Rust side (kind="interval"). The ONLY parity gap is the Ruby
DSL : `ruby/hecksagon/dsl/driven_adapter_builder.rb` has explicit `cron` /
`http_post` / `file_watch` methods but no `interval`. Add `interval(arg) = { kind:
"interval", arg: arg.to_s }` + a hecksagon IR parity fixture proving Ruby and Rust
emit byte-identical IR for `driving on interval`. Bounded, parity-verifiable,
mechanical. The advisor blessed this as safe even in a high-context session. It
closes the §3 "cron-not-interval" parity convention WITHOUT touching firing.

STATUS (2026-06-20) : THIS SLICE IS DONE. Ruby `interval` builder added
(driven_adapter_builder.rb), `interval_adapter.hecksagon` parity fixture added
(parity 194/194 green), DSL spec interval case added (7/7 green). The §3 crash is
closed : before the builder method, `driving on interval` raised NoMethodError in
the Ruby parser (no top-level method_missing) — THAT was "interval breaks parity."

GAP FOUND while landing it (fix-what-you-find, for the fresh head) : the canonical
parity dump EXCLUDES driving adapters entirely. Both dumps emit only name /
persistence / subscriptions / io_adapters / shell_adapters / gates / bindings
(canonical_ir.rb :: dump_hecksagon ~L524 ; main.rs :: dump_hecksagon ~L2933). So
driving handlers (cron AND interval) are NOT byte-compared — the parity test only
proves both parsers ACCEPT the file, not that kind/arg/dispatches agree. When the
scheduler work makes driving fire LIVE, also pull driving_adapters into BOTH
canonical dumps (mirror the io_adapters/shell_adapters shape) so interval+cron
kind/arg/dispatch are genuinely parity-verified. Low risk (both build from the
same source tokens via the already-parity-tested dispatch-attr machinery).

## Build order for the fresh head
1. Parity slice (Ruby interval builder + fixture + behaviors). Land + verify
   hecksagon parity green. This alone satisfies the §3 parity convention.
2. `storehouse drive` daemon : new subcommand, in-memory last-fired, poll loop,
   interval due-check, dispatch_cascade firing. Add to Procfile (one line).
3. Make cron fire LIVE through `drive` too (real 5-field expr matching) — sibling
   follow-on ; today cron is test-only and naive.
4. Behaviors for due/not-due/restart-early-fire. Tests must stay <1s (HECKS_NOW
   freezes the clock — use it for deterministic due-checks).

## Hazards / do-not-repeat
- Do NOT wire firing into run_loop (3× double-fire — verified structural).
- Do NOT copy the cron branch for interval ("fire every tick" throws away the N —
  advisor : symmetric-with-cron is incoherent because cron does not schedule).
- Sub-second cadence stays a dedicated --every loop, never a driving handler.
- Tests <1s ; freeze the clock with HECKS_NOW, never wall-clock sleeps.
