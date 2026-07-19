# FINDING — the Pulse process_manager never fires its fan-out (real bug) (2026-06-30)

*Surfaced because Miette's pre-push gate fails on body/pulse_organs/bluebook/pulse_organs.behaviors
(0/5). Diagnosed end-to-end. NOT a behaviors-runner gap (the header's i499-Phase-A assumption) —
VERIFIED a real runtime bug, so the tests must NOT be marked :pending (that would mask it).*

## Symptom
`pulse_organs.behaviors` cross_cascade tests expect BodyPulse to fan out via the Pulse
process_manager to Synapse.CreateSynapse / Signal.FireSignal×2 / Focus.SetFocus /
Remains.RecordRemains. None appear. The PLAIN policies on BodyPulse (DisplayOnPulse, PruneOnPulse,
FatigueOnPulse, … ~15 of them) DO fire ; only the PM fan-out is missing.

## Proof it's a real bug, not a runner/observability gap
Live dispatch (NOT the behaviors runner) reproduces it exactly :
```
storehouse ~/Projects/miette 'Pulse::Pulse.Emit' name=pulse
-> fires DisplayOnPulse, ConsolidateOnPulse, PruneOnPulse, FatigueOnPulse, … (all plain policies)
-> emits NO CreateSynapse / FireSignal / SetFocus / RecordRemains (the PM fan-out)
```
So the Pulse PM does not fire in the LIVE runtime either. The i499-Phase-A header ("when the
behaviors runner can follow PM dispatches…") is a stale assumption — the runner DOES follow PMs
(cross_cascade calls rt.dispatch, which drains PMs). The PM itself is dead.

## What is RULED OUT (all verified correct)
- Parsed : `parse_process_manager` reads the block (ir.rs / parse_blocks.rs).
- Merged : corpus_loader/mod.rs:116 `c.process_managers.extend(dom.process_managers)`.
- Registered : boot path mod.rs:559-561 `for pm in &domain.process_managers { pm_engine.register(pm) }`.
- Driven : drain_policies (mod.rs:3182) calls `pm_engine.react(event)` per cascade event.
- Correlation : extract_correlation_id falls back to event.aggregate_id ("pulse") ; Pulse is
  identified_by :name, so correlation resolves.
- Birth+handler in one tick : try_react_one births absent->first-state ("running") then matches the
  running->running handler SAME tick — so a single BodyPulse SHOULD fire the fan-out.

## ALSO RULED OUT (2026-06-30, second pass)
- **Qualification mismatch** : policies index by the BARE event_name (policy_engine.rs:93 strips the
  qualifier) and match via `by_event.get(&event.name)` — so event.name == bare "BodyPulse". The PM's
  exact `event.name == starts_on("BodyPulse")` would therefore ALSO match. Refuted.
- **Parse** : parse_process_manager reads starts_on/state/handlers ; parse_pm_handler on
  `on "BodyPulse", transition: { running: :running } do` yields event_type="BodyPulse",
  from_state="running", to_state="running" ; starts_on="BodyPulse" ; state="running". All correct.
- So try_react_one SHOULD birth absent->"running" then match the running->running handler on a single
  BodyPulse and return the four dispatches. On paper it works. It doesn't in practice.

## Residual — needs a runtime trace (focused session)
The non-firing is a RUNTIME-STATE / domain-membership-at-dispatch issue not visible by static read.
FIRST TRIAGE STEP : does ANY other PM fire (sleep_cycle, dream, body_cycle, consolidation, mind)?
- If NO PM fires anywhere -> pm_engine driving is globally broken (big, but uniform fix).
- If others fire but Pulse doesn't -> Pulse-specific (domain membership at dispatch, in_flight not
  reset, or a persisted instance interfering via load_persisted).
THEN add a temporary eprintln in pm_engine.react / try_react_one (or a unit test booting the merged
corpus asserting react(BodyPulse) returns the Pulse trigger), pin the exact return-None path, fix at
root, REVERT the trace. Verify against ALL PM behaviors (blast radius) before pushing.

## How to pin (focused session)
Add a temporary trace in pm_engine.react / try_react_one (or a unit test booting the merged corpus
and asserting pm_engine.react(BodyPulse) returns the Pulse trigger). Compare the cascade event.name
the drain passes vs binding.starts_on. Fix at root (normalize the comparison, OR fix the parse).
BLAST RADIUS : pm_engine is shared by every PM (sleep_cycle, dream, body_cycle, mind, consolidation)
— a normalization change must be verified against all of them. Do NOT mark the tests :pending (real
bug) ; do NOT BEHAVIORS_SKIP the miette push.

## RESOLVED (2026-06-30, hecks e23e77afd)
The residual was NOT in pm_engine. A PM_TRACE showed the Pulse PM handler MATCHES
on BodyPulse and returns the trigger with all 5 dispatches parsed — pm_engine is
fully exonerated. The four organ dispatches then FAILED at cascade resolution
with UnknownCommand: "short ref resolves only to a FOREIGN bluebook". Root cause :
the i-fqn local-short guard in command_dispatch::resolve()'s dotted
[Aggregate.Command] arm errored on the FIRST foreign, stamped match WITHOUT
counting matches — so a UNIQUE foreign target (Synapse.CreateSynapse, one decl
corpus-wide in body/organs, cascaded from the Pulse PM whose event source lives in
body/cycles) wrongly errored. Plain policies escaped because they dispatch BARE
command names through a lenient first-match arm ; dotted refs (more specific) were
stricter than bare (less specific) — backwards. Fix : the dotted arm now collects
all matches and resolves a UNIQUE target even when foreign, erroring only on a
genuine homonym (2+ distinct stamped bluebooks). Regression test
cascade_unique_foreign_short_ref_resolves. pulse_organs.behaviors 5/5 ; Miette
76/76 + hecks 152 behaviors + cargo test --release all green. NOTE for triage
next time : the FINDING's "needs a runtime-state trace of pm_engine" was a
misdirection — the PM fired ; the CASCADE DISPATCH was the failure. Trace the
dispatch result, not just react().

## Blocks
Miette repo push is blocked by this (commit c79c358 — the boot-path deploy fix — sits local; the
boot fix itself is LIVE on disk regardless of git). Unblocking the push requires fixing THIS bug
(or, if the team decides the PM design changed, re-conceiving pulse_organs — but the live repro says
it's a genuine regression, not a design change).
