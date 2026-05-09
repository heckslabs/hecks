# runtime-pm-execution branch — debrief

Built off `dream-study`. Closes the bluebook → IR → runtime arc for
process_managers in Rust. Three layers landed (Phase A + Phase B v1 +
Phase C) ; production activation gated on Phase D (PM state persistence
to heki) which is its own follow-on branch.

## What landed

### Phase A — Rust PMEngine (state-machine interpreter)

- `rust/src/runtime/pm_engine.rs` (NEW) — generic state-machine interpreter
  for any process_manager declared in bluebook. Mirror of `policy_engine.rs`
  shape with per-correlation state added. Get-or-create-on-starts_on
  semantics. Reentrancy guarded.
- `rust/src/runtime/mod.rs` — wires PMEngine into Runtime alongside
  PolicyEngine ; `drain_policies` drives PM react on every event.
- 3/3 unit tests green in <1ms covering full lifecycle, no-op for
  unrelated events, isolated correlation_ids.

### Phase B v1 — Declarative `dispatch` keyword

- `ruby/hecks/dsl/process_manager_builder.rb` — `on "Event", transition: ... do
  dispatch "Aggregate.Command" end`. Block arity discriminates Ruby-proc
  form from declarative form. OnHandlerBuilder captures one or more
  dispatches per handler.
- `ruby/hecks/bluebook_model/behavior/process_manager.rb` — Handler struct
  gains `:dispatches` field defaulting to `[]`.
- `rust/src/parse_blocks.rs` — action-body indent-skip walks the block
  capturing `dispatch "..."` lines into the handler's dispatches list.
- `rust/src/ir.rs` — `ProcessManagerHandler.dispatches: Vec<String>`.
- `rust/src/dump.rs` + `parity/canonical_ir.rb` — both sides emit
  dispatches in canonical JSON. Parity contract intact.
- `parity/bluebooks/20_process_manager.bluebook` — fixture extended
  with declarative-form handler ; byte-identical IR confirmed.

### Phase C — SleepCycle PM declarative

- `body/sleep/sleep_cycle.bluebook` — all 9 handlers refactored from
  Ruby-proc form to declarative dispatch. Conditional routing (cycle 8
  lucid vs regular ; pulses-needed cap) moves to Body's existing command
  given clauses ; the PM dispatches BOTH candidates and Body picks via
  given matching. GivenFailed is design-level — non-matching command
  short-circuits cleanly without log noise.

## Verifications

- 26/26 spec/hecks/dsl + spec/hecks/runtime PM specs green in 8ms
- 3/3 cargo test pm_engine green
- cargo build --release : clean
- pizzas smoke : green (PMs no-op when not declared)
- parity : 320/322 (corpus + 2 known drift) — miette 123/123
- in_memory_full_night : 22/22 green (BehaviorRuntime path unaffected
  by refactor)

## Phase D — PM state persistence to heki ✓ LANDED

Closed the production-activation gap. Each `hecks-life` subprocess
fork now loads existing PM instances from heki on Runtime boot,
persists transitions after each react. State accumulates across forks ;
PMs declared in bluebook drive the cycle in production.

Implementation :

1. **Heki path convention** — `<data_dir>/process_managers/<pm_name_snake>.heki`,
   one file per PM, each row keyed by correlation_id, record carries
   `{state, last_event, updated_at}`.
2. **PMEngine.load_persisted(data_dir)** — called once in
   `Runtime::boot_with_data_dir` after register ; reads each PM's
   heki + populates `instances` hash. Missing files = empty store
   (first-run case).
3. **PMEngine.persist_instance(pm_name, correlation_id, data_dir)** —
   called from `drain_policies` after each PM trigger fires. Best-effort —
   write failure doesn't abort cascade.
4. **Race-condition handling** — last-write-wins. The daemon model
   dispatches one event per fork ; concurrent same-instance writes are
   rare. Tightening (file lock or CAS) is its own follow-on if production
   reveals contention.
5. **PM-name-rename migration** — out of scope for first cut ; mirrors
   aggregate rename pattern (manual migration step in the rename PR).

Tests : 4/4 pm_engine green including `persists_and_reloads_instance_state`
(subprocess 1 transitions + persists ; subprocess 2 loads + further
transitions on top work as expected).

Commit : `f18570c7`.

## Phase E — staging : co-fire with mindstream as parallel safety check

Phase D enables PM-driven dispatch in production daemons but doesn't
yet retire mindstream.sh's sleep branch. Bootstrap risk : if no
SleepEntered event fires after the binary update, SleepCycle PM's
instance doesn't exist in heki (starts_on is SleepEntered) and the
body would get stuck mid-sleep with no advances.

Safer staging :

- **Phase E (now)** : leave mindstream's sleep branch in place. PMs
  co-fire next sleep cycle. mindstream + PM both dispatch advance
  commands ; given clauses pick winner ; only the matching command
  fires (the others GivenFailed cleanly). No behavior change, but
  `process_managers/sleep_cycle.heki` populates as a verification trace.
- **Phase F (next branch)** : after one overnight verifies the heki
  shows correct transitions, mindstream's sleep branch deletes (collapses
  ~25 LOC). The sleep cycle is genuinely PM-driven from that point.

This matches the dream-study commitment statement : *"body keeps
running through every PR."* Phase D is structurally the keystone ;
Phase F is the cosmetic retirement once verified.

## Followups (after Phase D)

- **Phase E — retire mindstream.sh sleep branch** : once PMs drive the
  cycle in production, the shell's per-tick advancement dispatches become
  redundant. Delete or shrink to one-line shebang.
- **Refactor Mind / Dream / Lucidity PMs to declarative** : same
  pattern as Phase C ; activates the rest of the five-thing ontology.
- **Witness append-only entity (Phase 8b)** : adds the WitnessedMoment
  entity to mind/awareness/witness.bluebook ; routes Observe to append
  Moment instead of overwriting singleton.

## Branch state

- Off `dream-study` (which carries Phase 1+2+3 + 4-10 from the dream-study session)
- Four commits :
  - `2cd7cd0b` — Phase A (PMEngine) + Phase B v1 (dispatch keyword)
  - `f6098b0` — Phase C (SleepCycle PM declarative)
  - `dce2f10`  — initial debrief
  - `f18570c7` — Phase D (PM state persistence to heki)

Working tree clean. Production-activation-ready ; the cycle drives
through PMs starting next SleepEntered. Phase F (mindstream sleep
branch retirement) is its own follow-on once Phase E (overnight
co-fire verification) passes.
