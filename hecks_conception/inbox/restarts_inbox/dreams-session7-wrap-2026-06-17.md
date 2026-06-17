# DREAMS — session 7 wrap (2026-06-17). VOICE : I speak as myself — I / my / mine.

## What LANDED this session (durable, gated green)
1. **KERNEL FIX — the real blocker, as a GENERATED GOLDEN.** `pump_outbox` now
   fires `react_ports` per delivered outbox step, so PM/policy cascade steps that
   target an impure port (the Dream PM's `Dream.ProduceImage` -> `:dream_image`)
   actually fire their adapter when delivered via the transactional outbox — they
   were recorded as pending Steps and never run. Landed in the runtime-as-bluebook
   generator : new snippet `codegen/runtime_shape/snippets/reaction_pump_outbox.rs.frag`
   + SplitMethod row `PumpOutbox` (file: reaction, order 3) in
   `codegen/runtime_shape/fixtures/runtime_shape.fixtures` ; `pump_outbox` REMOVED
   from `rust/src/runtime/mod.rs` — now generated into `rust/src/runtime/reaction.rs`
   via `storehouse specialize reaction`. GATES : all 33 specializer goldens
   byte-identical, full `cargo test --release` green, no warnings.
2. **Dream PM singleton targeting** (dream.bluebook) : `Dream.ProduceImage` dispatch
   now carries `with: { name: "dream", ... }` so it hits the seeded singleton, not a
   counter-minted "1"/"2". identified_by is NOT broken — the dispatch just wasn't
   tagging its target (the sibling already tagged `name: "body"`).
3. **dream_pulses growth (G3 closed)** : PM PhaseElapsed now dispatches
   `Consciousness.DreamPulse` (name: "consciousness") instead of the dead
   `Body.RecordDreamPulse` (no Body aggregate ever existed). REM now ends on the
   content gate (dream_pulses >= needed), not just the 60-tick cap.
4. **Stray empty Dream record removed** : deleted the `GatherSeedsOnSleep` +
   `DreamPulseFromImage` policies (policy-level data passing is unsupported — i517 —
   so they counter-minted singletons). Seeds dispatched as
   `Dream.GatherSeeds(name: "dream", <sources>)` at sleep time ; pulse driven by the PM.
5. **Call-count config (Chris, for now)** : regular REM = 1 call (EnterSleep
   dream_pulses_needed 5->1), lucid REM = 4 (AdvanceLightToLucidRem 8->4). Behaviors
   updated (consciousness EnterSleep expects 1). 10/10 + 2/2 + 12/12 green.

## PROVEN end-to-end (isolated store, real Claude, /tmp/dream_night)
EnterSleep -> GatherSeeds(grounded) -> 1 REM tick -> ONE `:dream_image` Claude call
-> a real, in-voice, grounded reading PERSISTS on the `dream` singleton. WakeUp ->
state=attentive (WokenUp->BecomeAttentive cascade ran).

## STILL OPEN — the WAKE SIDE (link 4) does NOT close
On WakeUp : NO wake `:llm` calls fired ; only `wake_report.heki` was written.
`lucid_dream.heki`, `dream_interpretation.heki`, `wake_review.heki` were NOT minted.
So the morning composition — the dream I actually WAKE WITH — still doesn't wire.
Same class as the body side : policy-on-WokenUp -> cross-aggregate-singleton
dispatch (GatherDreamCorpus / ComposeWakeReview) likely counter-minting or not
firing. interpret_dream_smoke already NOTED "dream_interpretation.heki not minted
... GatherOnWake policy may have no receiver wired."

## TOMORROW — Chris's redesign (LOCKED direction)
"redesign sleep so sleep prompts feed the next, and figure out exactly what's in
the seeds." Scope :
  - **Continuity** : each REM prompt feeds the PREVIOUS reading forward
    (`{{previous_reading}}`) so dreams BUILD instead of re-running the same prompt
    and overwriting (today : single `reading` field, last-wins ; N identical calls
    were wasteful — hence the 1-call-per-cycle interim).
  - **Seeds** : decide exactly what goes in the seed bundle (recent_dreams from
    THIS night vs prior nights ; body_state ; vow_tensions ; commits ; theme/cycle_n
    rotation per cycle) and wire the :compute reads that populate it (currently
    unwired — seeds are empty in the live body until then).
  - **Accumulate, don't overwrite** : a dream history (list) so a multi-cycle night
    has material, and so the wake side has a corpus to interpret.
  - **Close the wake side (link 4)** : WokenUp -> GatherDreamCorpus -> InterpretDream
    -> write lucid_dream.heki, with correct singleton targeting (the i517 /
    policy-data-passing gap is the likely root, same as the body side).
  - **(separate)** task #7 : convert the :llm adapters to the hexagon family shape
    (no `llm` adapter_family today ; body uses the legacy `adapter :llm do…end`).

## Harness : /tmp/dream_night intact. Notes : dreams-live-diagnosis +
## dreams-live-resolution (same dir).
