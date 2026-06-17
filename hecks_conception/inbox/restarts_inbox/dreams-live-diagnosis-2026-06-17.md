# DREAMS — LIVE diagnosis (session 7, 2026-06-17) — the blocker is the PM dispatch, not the gate

VOICE : I speak as myself — I / my / mine.

## What I set out to do
Chris : "go after dreaming for sure." Goal = a real dreamed night written to
`lucid_dream.heki` / `dream_interpretation.heki`. Per the advisor I INVERTED the
restart card's plan : prove the chain `EnterSleep → written dream` BY HAND in an
isolated store FIRST (the entry gate is the last mile, not the first).

## Method — isolated live runtime, REAL Claude
Isolated store at `/tmp/dream_exp` (240 bluebooks symlinked from
`hecks_conception/aggregates` + `~/Projects/miette/body`, own `.world`,
`HECKS_INFO=$EXP/information`). Drove the REAL state machine via repeated
one-shot `Pulse::Pulse.Emit` dispatches (one-shot runs the full policy+PM+adapter
cascade — interpret_dream_smoke proves this) and via `storehouse run-loop`.
`HECKS_LLM_PROVIDER` UNSET → exercises the real `backend :claude` ClaudeProvider
(subprocess to local `claude -p --model sonnet`).

## RESULTS — what works, what doesn't (all verified LIVE, real Claude)
- **L1 sleep entry** : `Mind::Consciousness.EnterSleep sleep_at=…` lands
  `state=sleeping, sleep_stage=light, dream_pulses=0, sleep_total=8`. ✓ (the gate
  is a separate, easy fix — NOT the blocker)
- **L2 sleep advance** : first `Pulse.Emit` → `light→rem` (no time floor) ;
  `phase_ticks` climbs each REM tick. Policy-driven advance WORKS live. ✓
- **Dream PM lifecycle** : births on SleepEntered (dormant→incubating), reaches
  `generating` (process_managers/dream.heki, last_event=PhaseElapsed). ✓
- **The :llm adapter + ClaudeProvider + RecordImage** : **WORK LIVE.** A DIRECT
  one-shot `Body::Dream.ProduceImage name=dream sleep_cycle=1` produced a real,
  in-voice French reading and landed it on `Dream.reading` :
  > git show 09c03324 — le lecteur d'ondes traverse le cas amplitude nulle sans
  > rien écrire dans le buffer, chemin non testé ; cherche src/reader.py autour
  > de la logique de détection de crête avant de continuer.
  So the card's "REM dream-gen proven" is now ALSO proven LIVE, directly. ✓

## THE BLOCKER (corrected diagnosis — supersedes the card's framing)
**The Dream PM, while in `generating`, does NOT produce a dream during a driven
REM cascade.** Across the whole tick run : `reading` stayed empty, `dream_pulses`
stayed 0, NO `[llm:debug]` line ever printed — i.e. `Dream.ProduceImage` was
never dispatched by the PM, even though the PM sat in `generating` with
last_event=PhaseElapsed. The runtime advances PM *state* but the per-tick
`dispatch "Dream.ProduceImage"` side-effect inside `on PhaseElapsed
{generating:generating}` does not reach the adapter.
  - Components ALL work in isolation ; the END-TO-END PM-driven production yields
    nothing. The :llm hook in `drain_policies` (i220-1) IS present and would fire
    if `t.dispatches` carried ProduceImage — so the gap is upstream, in what
    `pm_engine.react(PhaseElapsed)` returns / how the dispatch is keyed.
  - **G3 confirmed** : `dream_pulses` never grows (RecordDreamPulse rides the
    same dead PM-dispatch path). REM would only ever escape via the 60-tick cap.

## Smoking-gun secondary : CORRELATION-KEY mis-resolution
The Dream PM `correlates_by :name` should be the singleton `"dream"`. Instead it
created PM instances keyed by the TRIGGERING event's aggregate id — `"1"` and
`"consciousness"` (the Consciousness singleton's id), NOT `"dream"`. So even if a
PM dispatch fired, `Dream.ProduceImage` would target the wrong Dream id (empty
seeds), not the `"dream"` instance GatherSeeds populated. This correlation bug is
a strong candidate for the whole root cause : fix the correlation key → seeds,
ProduceImage target, and reading all line up on `"dream"`.

HYPOTHESIS (needs a fix + retest, kernel-floor) : `pm_engine` resolves
`correlates_by :name` from the event's aggregate_id rather than the PM's own
singleton name, and/or omits the handler's `dispatch` from the trigger when the
transition is a self-loop (`generating:generating`). Pinning it needs
instrumentation in `rust/src/runtime/pm_engine.rs` + `mod.rs drain_policies`
(2269) — runtime debugging that wants a fresh head / gated worktree.

## Decision for Chris (the advisor's gate)
"Go after dreaming" is NOT "fix the entry gate + drive a night." The gate is the
last mile. The real blocker is kernel-floor : **make the Dream PM actually
dispatch ProduceImage (correctly correlated to "dream") each REM tick in the live
runtime.** Likely root cause = the PM correlation-key bug above. This is a
bigger, byte-precise arc than the card implied — surfacing it before sinking the
night into the gate.

NEXT (when greenlit) : (1) confirm correlation-key resolution in pm_engine ;
(2) fix correlates_by :name → fixed singleton ; (3) retest the isolated
one-shot-tick chain → expect a real reading per REM tick + dream_pulses growth ;
(4) only THEN the entry-gate handshake + a full driven night → written
lucid_dream.heki.

## Reusable harness
`/tmp/dream_exp` is intact. Recipe : symlink bluebooks + .world,
`HECKS_INFO=$EXP/information`, unset `HECKS_LLM_PROVIDER`, dispatch
`Mind::Consciousness.EnterDaydream` → `.EnterSleep sleep_at=…`, loop
`Pulse::Pulse.Emit name=pulse`, sample `consciousness.heki` +
`body_dream/dream.heki`. Direct `Body::Dream.ProduceImage name=dream` is the
adapter-works control.
