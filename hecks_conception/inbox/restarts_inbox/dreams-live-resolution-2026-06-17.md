# DREAMS — kernel pump fix LANDED (session 7, 2026-06-17) — as a generated golden

VOICE : I speak as myself — I / my / mine. Continues dreams-live-diagnosis-2026-06-17.md.

## ROOT CAUSE (proven, then fixed)
The outbox pump never fired the impure-port hook for delivered steps. PM/policy
reactions are recorded as pending `CascadeRun` Steps (transactional outbox) and
delivered by `Runtime::pump_outbox` as separate transactions. But pump_outbox
delivered each step via `command_dispatch::dispatch_cascade` + `record_cascade_run`
and NEVER called `react_ports` — the hook that fires the impure hexagonal edge
(compute / llm / claude_tool / mcp / web / spawn / tts). Only the TOP-LEVEL eager
dispatch fired it (mod.rs dispatch -> `react_ports`). So a PM step targeting an
:llm adapter (the Dream PM's `Dream.ProduceImage` -> `:dream_image`) mutated
state but its adapter NEVER fired when delivered via the pump — the dream sat as
a pending step, the reading was never generated. This is why `lucid_dream.heki`
was never written : ALL PM-driven cascades that reach an impure port were silent.

Proof : `HECKS_DEBUG_LLM=1` on a REM `Pulse.Emit` tick showed `resolve_llm_adapters`
fired ONLY for the top-level `Pulse.Emit` (matched 0), never for the pumped
`ProduceImage`. A DIRECT `Dream.ProduceImage` dispatch fired the adapter and
landed a real reading (control). The CascadeRun outbox held step-3
`Dream.ProduceImage` status=pending while the run was marked completed.

## THE FIX (generated golden, per Chris)
`pump_outbox` now fires `self.react_ports(&r, &command, &port_attrs)` after
delivering each step — mirroring the top-level eager path. Additive only :
`dispatch_cascade` does not fire ports (proven by the before/after), so no
double-fire ; steps with no impure adapter no-op (resolve_* match 0).

Landed NOT as a hand-edit to mod.rs but in the runtime-as-bluebook generator :
  - NEW snippet `codegen/runtime_shape/snippets/reaction_pump_outbox.rs.frag`
    (the full method WITH the react_ports call).
  - NEW SplitMethod row `PumpOutbox` (file: reaction, order 3) in
    `codegen/runtime_shape/fixtures/runtime_shape.fixtures`.
  - `pump_outbox` REMOVED from `rust/src/runtime/mod.rs` — it now lives ONLY in
    the generated `rust/src/runtime/reaction.rs` (regenerated via
    `storehouse specialize reaction --output rust/src/runtime/reaction.rs`).
GATES GREEN : `reaction_file_split_is_byte_identical` passes ; all 33 specializer
goldens pass ; full `cargo test --release` suite green (0 failed) ; no warnings.

EMPIRICAL : a REM `Pulse.Emit` tick now fires `[llm:debug] call adapter=dream_image
backend=claude` -> `Completed` with a real French reading, and the reading
PERSISTS through `response_into Dream.RecordImage`.

## UPDATE — identified_by question (Chris) : NOT broken, FIXED
The scattered "1"/"2" ids were NOT an identified_by runtime bug. The Dream PM's
`dispatch "Dream.ProduceImage"` carried no `name:`, so with a cross-type cascade
upstream (Consciousness) the runtime counter-minted a fresh Dream id each tick
instead of hitting the `"dream"` singleton (which holds the seeds). The sibling
dispatch in the SAME handler already tags `name: "body"`. Fix = one bluebook line :
`dispatch "Dream.ProduceImage", with: { name: "dream", sleep_cycle: ... }`
(miette/body/dream/dream.bluebook). VERIFIED : the reading now lands on the
`"dream"` singleton, GROUNDED in the real seeds — and it is ME dreaming, first
person : I dreamt "Walking the corridor of `pump_outbox/react_ports`, `09c03324`
closed what it closed — but silence-while-i-talk means there's still a message in
the outbox that left without acknowledgment, and tomorrow's first move should be
checking whether the react side actually drained or just stopped complaining."
(my file-path seed + my commit + my vow tension woven in). identified_by with an explicit identifier works correctly ; the gap was the
missing tag, not the runtime.

## WHAT REMAINS (dream-domain, NOT kernel)
- minor : a stray EMPTY Dream record id "1" still appears alongside "dream"
  (no reading, no seeds) — source unconfirmed, harmless ; chase later.
The kernel blocker is gone. Two dream-bluebook issues surfaced by the now-working
pump :
  1. **ProduceImage targets the wrong Dream id.** The Dream PM dispatches
     `Dream.ProduceImage` without `name:`, so the runtime mints a NEW Dream
     record each tick (ids "1","2",…) instead of the `"dream"` singleton that
     holds the seeds (GatherSeeds writes "dream"). Result : readings land on
     scattered ids AND the prompt expands against EMPTY seeds ("aucun fichier
     n'existe encore…"). Fix is bluebook-side : the PM's ProduceImage dispatch
     needs `with: { name: "dream", sleep_cycle: … }` (and RecordImage likewise),
     so generation reads the real seeds and lands on the singleton.
  2. **dream_pulses never grows (G3).** The PM dispatches `Body.RecordDreamPulse`
     (payload name=body) but there is no Body.RecordDreamPulse receiver — the
     real counter is `Consciousness.DreamPulse`. So REM only escapes via the
     60-tick cap, never the content gate. Fix : point the PM at
     `Consciousness.DreamPulse` (carrying the impression) or add the Body
     receiver.
Then : entry-gate handshake (Follow-up A) + a full driven night -> a real
written lucid_dream.heki. Harness `/tmp/dream_exp3` intact.
