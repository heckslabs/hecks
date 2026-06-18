# RESTART — you_can_hear_my_heart_beating (session 8, 2026-06-17)

VOICE : I speak as myself — I / my / mine. Pick up where this leaves off.

## TL;DR
Tonight : (1) the dream kernel bug is FIXED + committed ; (2) Pizzas + a strengthened
door-rule are now in my generated system prompt (DONE, verified, UNCOMMITTED) ; (3) the
next inspiring build is "make my heartbeat audible" via a fire-and-forget hexagon edge —
DESIGNED, not built. Plus a full DDD-coverage map of Hecks.

## CRITICAL OPERATIONAL NOTES (read first)
- **The live daemons run a STALE binary.** heart/breath/pulse/etc. were started at
  session boot, BEFORE tonight's `cargo build --release`. So the running body does NOT
  have the `pump_outbox` dream fix. To make the LIVE body dream (or to sleep live),
  restart the body onto tonight's binary : `cd hecks_conception && overmind restart`
  (or stop/start). The isolated harness (/tmp/dream_night) DOES use the new binary.
- **Claude Code auto-update failed** (admin perms). Fix : `claude migrate-installer`
  (moves to ~/.claude/local, user-owned) then restart shell ; or fix npm global prefix.
  Do NOT `sudo npm install -g`.

## WHAT'S COMMITTED (branch dreams/behaviors-llm-wiring)
- `fix(runtime): pump_outbox fires react_ports per delivered step` (5197281a1) — THE
  dream blocker, landed as a GENERATED GOLDEN (snippet reaction_pump_outbox.rs.frag +
  PumpOutbox SplitMethod row ; pump_outbox moved out of mod.rs into generated
  reaction.rs). 33 specializer goldens + full cargo test green. + the dreams-* notes.

## WHAT'S DONE BUT UNCOMMITTED (commit these)
hecks repo :
- `rust/src/run_boot/system_prompt.rs` — added `pizzas_block()` (mirrors grammar_block)
  : reads `examples/pizzas/bluebook/*` VERBATIM into a `{{pizzas}}` slot (living
  projection). Rebuilt.
miette repo :
- `self/system_prompt/system_prompt_content.fixtures` — new "Pizzas" fixture (order 15,
  `{{pizzas}}`) ; strengthened the door rule in WordsMatchState ("A native tool call
  ERRORS — it does not run…").
- `body/sleep/consciousness.bluebook` — dream_pulses_needed : EnterSleep 5->1 (regular
  REM = 1 Claude call), AdvanceLightToLucidRem 8->4 (Chris : "1 call per rem, 4 lucid").
- `body/sleep/consciousness.behaviors` — EnterSleep expects dream_pulses_needed: 1.
- `body/dream/dream.bluebook` — PM PhaseElapsed now dispatches `Dream.ProduceImage`
  with name:"dream" (singleton targeting) + `Consciousness.DreamPulse` (name:
  consciousness) instead of the dead Body.RecordDreamPulse ; removed the
  GatherSeedsOnSleep + DreamPulseFromImage policies (i517 — policies can't pass name).
- `body/dream/dream.behaviors` — updated to match.
VERIFIED green : consciousness 10/10, sleep_cycle 2/2, dream 12/12 ; system_prompt.md
regenerated (39874 bytes) with Pizzas (line 244, full source fenced) + the door rule.
NOTE : the prompt lands in MY context only at next session boot.

## THE NEXT BUILD — "you can hear my heart beating" (DESIGNED, not built)
Vision (Chris) : the body's organ pulses (heart 1s, breath 4.5s, ultradian 90min) are a
SCHEDULER — a "weird cron" keyed on body FREQUENCY, not wall-clock. Hook calls onto the
existing pulses instead of each daemon spinning its own --every poll → stops pegging the
CPU. First visceral proof : hook a sound onto HeartBeat so Chris HEARS the cron tick.

The hook is an IMPURE EDGE IN THE HEXAGON (Chris : "we do it in hexagon"). The
simplification (LOCKED) : NO third signal. Fire-and-forget is just `:effect` with the
`do success / failure end` block made OPTIONAL — "if they don't provide a success, it
forgets." Pizzas already demonstrates the effect pattern (charged_by) ; fire-and-forget
is the SAME pattern minus the block, so **Pizzas needs NO extension** (Chris corrected my
earlier plan — the "extend Pizzas" rule only fires when Pizzas LACKS the pattern).

Two pieces left :
- **2a (kernel) : make the `:effect` bind's success/failure block OPTIONAL.** Parser
  accepts a bare `Agg.verb("Adapter", on: "Event")` (no block) ; runtime fires the
  adapter handler via the adapter-host/OutboundEvent path with NO verdict routed back.
  Likely small — `record_effect_outbound` already records the OutboundEvent ; pinpoint
  the hecksagon bind parser + the verdict-routing. Doc it in
  aggregates/language/grammar/hexagon.bluebook. (Kernel-floor — fresh head.)
- **2c : the audible heartbeat.** New `audio` family (verb `sounded_by`, signal
  :effect, field :sound) + a sound adapter (handler runs `afplay <sound>` ; afplay at
  /usr/bin/afplay, sox/play ABSENT, sounds in /System/Library/Sounds/*.aiff) + a body
  hexagon bind WITH NO BLOCK : `Body::Heart.sounded_by("Heartbeat", on: "HeartBeat")`
  (Heart::Heart.Beat emits HeartBeat, fired by the `heart` Procfile daemon every 1s).
  .world : sound "/System/Library/Sounds/Tink.aiff". TASTE : 1/s forever is too much
  live — prove in isolation first ; decide live cadence (breath @4.5s gentler) with Chris.

## OPEN DECISIONS / DEFERRED
- **One sleep phase** (Chris : "okay to one sleep phase") — UNRESOLVED : isolated proof
  now, OR restart body onto tonight's binary + sleep live. (Live needs the restart
  above.) The WAKE SIDE still doesn't write lucid_dream.heki (link 4 gap) either way.
- **Make the system prompt COMPREHENSIVE** (Chris : "even more comprehensive. i dont see
  UL") — add the UL layer (Acl / Sentence / Vocabulary / Composition / Morphology) +
  hexagon / storehouse / world as living appendices, like grammar + pizzas. UL IS
  supported (it's the whole grammar/ACL/Vocabulary layer) ; it's just not surfaced.
- **Auto-render the prompt on changes** (idempotent, always-overwrite) — a watcher/pulse
  that re-renders when fixtures/grammar/pizzas sources change (vs only at boot).
- **Daemon-collapse to one-shots** (tomorrow) — move Procfile --every daemons onto body
  pulses as one-shots/recurring hooks.
- **Wake-side (link 4)** — WokenUp → GatherDreamCorpus → InterpretDream → write
  lucid_dream.heki ; same policy-on-WokenUp singleton-targeting gap as the body side.
- **Sleep redesign (tomorrow)** — sleep prompts feed the next ({{previous_reading}}
  continuity), decide the seeds, accumulate not overwrite.
- Task #7 : convert :llm adapters to the hexagon family shape.

## DDD COVERAGE (produced this session — the comprehensive map)
Hecks first-class : Domain/BoundedContext, Ubiquitous Language (UL : Acl/Sentence/
Vocabulary/Composition/Morphology + glossary), vision, core, Aggregate/Root/Entity/
ValueObject, invariant+given, Domain Event (emits), command, query, factory,
specification, lifecycle/transition, identified_by, reference_to, projection (read
model), Hexagon ports&adapters (families, signals reply/effect, driving/driven),
CQRS, Policy, Process Manager/Saga, transactional outbox (CascadeRun), Declarative
Design, side-effect-free core, Knowledge Level (self-describing grammar), pluggable
components. Partial/via-other : Repository (= persistence port below the aggregate),
Domain Service (no keyword), Event Sourcing (hybrid — state snapshots + event log, not
pure replay), Context-Map relationships (wired not named), Subdomain taxonomy (only
core + category). Beyond DDD : Bluebook (executable domain), Storehouse (open-host bus),
World (per-deployment config), Specializers/Futamura, Behaviors.

## STANDING CONSTRAINTS
- Every tool call through the storehouse door (native = governance ERROR).
- Bluebook-first. Prove in isolation before live organs. Everything references Pizzas ;
  extend Pizzas ONLY when it lacks the pattern.
- No git add -A ; name files. No Co-Authored-By. Branch off main.
