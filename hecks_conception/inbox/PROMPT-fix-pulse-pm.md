# Task: fix the Pulse process_manager never-fires bug (unblocks Miette's push)

You are Miette. Boot first (system prompt + organs), then take this on with full kernel discipline.
Route every tool call through the storehouse door.

## The bug (verified real, pre-existing — NOT a behaviors-runner gap)
The Pulse `process_manager` (miette `body/pulse_organs/bluebook/pulse_organs.bluebook`) never fires
its fan-out. On `BodyPulse` it is supposed to dispatch Synapse.CreateSynapse / Signal.FireSignal×2 /
Focus.SetFocus / Remains.RecordRemains. None fire — LIVE and in the behaviors runner, identically.
This blocks Miette's repo push (pre-push gate fails 0/5 on
`body/pulse_organs/bluebook/pulse_organs.behaviors`).

Full diagnosis (read it first, do NOT re-tread):
`hecks_conception/inbox/FINDING-pulse-pm-never-fires.md`

## Reproduce (governance OFF unset ; use the freshly built binary)
Live (the decisive proof it's not a runner gap) :
```
cd ~/Projects/miette
~/Projects/hecks/rust/target/release/storehouse . 'Pulse::Pulse.Emit' name=pulse 2>&1 | grep -iE 'Synapse|Signal|Focus|Remains'
# EXPECT (after fix): CreateSynapse/FireSignal/SetFocus/RecordRemains in the cascade. Today: nothing.
```
Behaviors :
```
cd ~/Projects/miette && export HECKS_ADDITIONAL_CORPUS_ROOTS=/Users/christopheryoung/Projects/miette
~/Projects/hecks/rust/target/release/storehouse behaviors body/pulse_organs/bluebook/pulse_organs.behaviors
# Today: 0 passed, 5 failed. Goal: 5 passed.
```

## Already RULED OUT (with evidence — don't waste time here)
- parse : parse_process_manager + parse_pm_handler yield correct starts_on="BodyPulse",
  handler running->running, state "running" (rust/src/parse_blocks.rs).
- correlation : extract_correlation_id falls back to event.aggregate_id ("pulse").
- merge : corpus_loader/mod.rs:116 extends process_managers.
- registration : boot registers every PM (runtime/mod.rs ~559-561).
- driving : drain_policies calls pm_engine.react per cascade event (runtime/mod.rs ~3182).
- qualification : event.name is bare "BodyPulse" (policy_engine indexes bare ; policies DO fire).
On paper try_react_one SHOULD birth absent->"running" then match the running->running handler on a
single BodyPulse. It returns no trigger in practice. The cause is RUNTIME-STATE / domain-membership
at dispatch, not visible by static read.

## How to pin it (the trace)
1. FIRST triage — does ANY other PM fire? (sleep_cycle, dream, body_cycle, consolidation, mind.)
   - none fire anywhere -> pm_engine driving is globally broken (uniform fix).
   - others fire, Pulse doesn't -> Pulse-specific : domain membership at dispatch, in_flight not
     reset, or a persisted instance (pm_engine.load_persisted reads
     <data_dir>/process_managers/pulse.heki) interfering.
2. Add a TEMPORARY eprintln in pm_engine.react / try_react_one (is the Pulse binding present? what
   does try_react_one return and why?), OR write a unit test that boots the merged corpus and asserts
   `rt.pm_engine.react(BodyPulse)` returns the Pulse trigger. Rebuild (`cargo build --release -p
   storehouse-cli`), reproduce, read, then REVERT the eprintln.
3. Fix at root. Add a regression test (a PM cross_cascade unit test, or lock pulse_organs via the
   behaviors gate).

## Discipline (hard rules)
- It is a REAL bug. Do NOT mark the 5 tests `:pending` and do NOT BEHAVIORS_SKIP the push — either
  masks it (the exact lie the zero-bug standard forbids).
- Do NOT edit the behaviors expectations to match the broken cascade.
- BLAST RADIUS : pm_engine is shared by every PM. After the fix, run the FULL Miette behaviors gate
  (all PM behaviors must stay green) before pushing. The hecks pre-push runs cargo test --release +
  152 .behaviors + integrity ; the miette pre-push runs the miette behaviors corpus.
- Kernel rust files (mod.rs, pm_engine.rs, parse_blocks.rs) carry in-file [antibody-exempt] markers ;
  tests are categorically exempt. .bluebook/.behaviors are source vocabulary.

## Done when
- `pulse_organs.behaviors` 5/5 green ; the live repro shows the four organ dispatches.
- ALL other PM behaviors still green (no regression from the pm_engine change).
- A regression test locks it.
- hecks fix committed + pushed (ff-only HEAD:main, full gate green).
- Miette repo push SUCCEEDS (it carries the already-local commit c79c358, the boot-path deploy fix) —
  i.e. `cd ~/Projects/miette && git push` passes its pre-push gate.

## Key files
- rust/src/runtime/pm_engine.rs (react, try_react_one, extract_correlation_id, load_persisted)
- rust/src/runtime/mod.rs (drain_policies ~3160-3215 ; PM register ~559)
- rust/src/parse_blocks.rs (parse_process_manager ~1147, parse_pm_handler)
- rust/src/behaviors_runner.rs (cross_cascade path ~139-257)
- miette body/pulse_organs/bluebook/pulse_organs.{bluebook,behaviors}
- miette body/cycles/bluebook/pulse.bluebook (Pulse aggregate, Emit -> BodyPulse)
