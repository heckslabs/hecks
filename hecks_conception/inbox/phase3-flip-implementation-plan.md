# Phase 3 — memory-floor flip : implementation-ready plan

_Derived 2026-06-28 after #2 conformance + a cross-process correctness fix.
Scope decided with Chris: **flip dev/test conceptions only ; the live body
trees stay Heki-floor** (they are now fully explicit-Heki). Build this on its
OWN branch/worktree with a TEST binary ; never hot-swap the live body's binary
until green + backed up._

## The load-bearing finding (why body stays Heki)

Memory is a **per-process HashMap**. The body is **multi-process** (daemon
loops, statusline, the dispatch door are separate OS processes). PROVEN: a
Memory aggregate written in proc A reads back `null` in proc B ; a Heki
aggregate round-trips via shared disk (BodyFelt vs Member control, 2026-06-28).

So for the body the axis is NOT "is the data re-derivable?" but "is it read by
a different process than writes it?" — in a daemon body, almost always yes.
Memory-as-floor is therefore BACKWARDS for the body: every aggregate you forget
to wire Heki becomes a SILENT cross-process break. Heki-floor is the safe
default for a running being. The flip's premise ("tests are memory") fits
world-less dev/test conceptions only.

Consequence already applied: Phase-2's 23 Memory wirings were reverted to Heki
(miette 8fd30a3) ; mietteai durable aggregates wired Heki (83b2c9b). The body
trees are all-Heki-explicit now, so the global kernel flip only bites world-less
conceptions — EXCEPT the one gap below.

## Five touch points

1. **Default floor** — `rust/src/runtime/persistence_resolution.rs`.
   `boot_with_data_dir` builds every repo Heki@data_dir. Make the floor
   `Backend::Memory` when NO binding and NO world resolves a backend.
   `apply_hexagon_persistence` (reads `persisted_by` bindings) already rebinds
   explicit Heki/Memory AFTER boot, so all body aggregates (explicit Heki) are
   untouched ; only binding-less + world-less aggregates fall to the new floor.

2. **`.test.world` precedence** — a `<name>.test.world` (same world parser)
   WINS over `<name>.world` when both present. Carries an explicit isolated
   `heki do; dir "$TMP/store" end`.

3. **The glob trap** — `rust/src/heki.rs` : `resolve_default_dir` AND
   `resolve_realm_dir` filter `p.extension() == "world"`. `foo.test.world` ends
   in `.world`, so prod discovery would wrongly pick it up. Discovery must SKIP
   files matching `*.test.world` unless test-resolving. (Check both fns ; both
   iterate `*.world`.)

4. **`OutboundEvent` injection** — THE gap that breaks "body stays Heki".
   `OutboundEvent` is a framework bluebook
   (`aggregates/framework/hexagon/bluebook/outbound_event.{bluebook,hecksagon,world}`)
   whose hexagon declares `persisted_by("Heki")`. The kernel INJECTS the
   OutboundEvent AGGREGATE into every runtime (runtime/mod.rs guards on
   `a.name == "OutboundEvent"`), but NOT its hexagon — so `backends` against
   miette/family/mietteai shows it UNWIRED. Today that's harmless (implicit
   Heki). POST-FLIP it falls to Memory and breaks the cross-process outbox
   (domain process writes, adapter-host process reads). FIX: inject the
   OutboundEvent persistence BINDING (or a synthetic `persisted_by("Heki")`)
   wherever the aggregate is injected, so it stays Heki in every runtime.
   VERIFY: `backends <any tree>` shows 0 unwired after.

5. **Rewrite the 8 persistence smoke tests** with `.test.world` carrying an
   explicit isolated `dir "$TMP/..."` (all 8 are multi-process, so all stay on
   disk, just explicit + named): consolidate, pulse_organs, pulse_fanout,
   body_cycles, status_golden, statusline_regression, interpret_dream,
   dream_content. (Names per the spec ; confirm against `hecks_conception/tests/*.sh`.)

## Build + verify discipline (isolation, then checkpoint)

1. Worktree off hecks `main` ; edit there ; `cargo build --release` to the
   worktree's OWN target/ (does NOT touch the live body's binary).
2. Verify with the TEST binary:
   - `backends` on miette / miette_family / mietteai → crown jewels still Heki,
     0 unwired (OutboundEvent now wired).
   - A world-less /tmp conception → aggregates resolve Memory (the floor flipped).
   - The 8 smoke tests pass against their `.test.world` explicit stores.
   - Behaviors + unit suite green.
3. ONLY THEN deploy: back up the live binary
   (`~/Projects/hecks/rust/target/release/storehouse`), copy the new one in,
   restart the body, and PROVE crown jewels round-trip cross-process
   (MietteMemory/Vows write-in-A read-in-B) before declaring done.
4. Revert path: keep the binary backup ; `overmind quit` + restore + restart.

## REAL CHAIN — verified in-code + empirically (2026-06-28, deeper than the 5 above)

The 5 touch points are correct but UNDERSTATE the entanglement. Verified facts:

- **World-less → DISK today, NOT memory.** A bare /tmp `Widget.bluebook` (no world,
  no binding) round-trips cross-process and `backends` shows it `Heki` at
  `~/Library/.../Hecks/hecks` — it POLLUTES the shared hecks store. So the
  `resolve_info_dir` doc-comment ("bare bluebook → MEMORY ; infer_data_dir returns
  None") is STALE/ASPIRATIONAL for the dispatch path. The flip is genuinely undone.

- **The real opt-out is the `info_dir` GLOBAL FALLBACK, not `boot_with_data_dir`.**
  Dispatch resolves data_dir = `world_heki_dir(path).or(info_dir)` (`run.rs:223-224`)
  → `storehouse_router::info_dir` → `heki::resolve_info_dir` (heki.rs:1160), which
  returns the global hecks store for ANY world-less conception. THIS is the line
  the flip must change: world-less must resolve `None` (→ Memory floor), never the
  global store. Touch point #1 (`boot_with_data_dir`) is downstream of this.

- **Two production boot paths, BOTH apply bindings** (de-risks the floor flip):
  dispatch `run.rs:150` and serve `server/multi.rs:205` both use
  `boot_with_hecksagons` → attaches hecksagons → `apply_hexagon_persistence`
  rebinds explicit `persisted_by`. So bound (all body) aggregates rebind to
  Heki@realm regardless of the floor. CONFIRM the `storehouse loop` handler also
  routes through this (run.rs dispatch) BEFORE flipping — if a loop ever booted via
  plain `Runtime::boot` (Heki-floor-reliant, no rebind), Memory-floor would drop
  its organs. (Evidence points to boot_with_hecksagons everywhere in prod; the
  loop_driver.rs:368 `Runtime::boot` is a TEST helper, not prod.)

- **`ensure_outbox_substrate` ALREADY injects the OutboundEvent AGGREGATE** (mod.rs,
  in `boot_with_hecksagons`, gated on an effect binding present). Touch point #4 is
  therefore SMALLER than feared: not "inject the aggregate" but "also attach its
  `persisted_by(\"Heki\")` binding" so it survives the Memory floor. Verify with
  `backends <any tree>` → OutboundEvent `wired`, 0 unwired.

- **`realm_store_dir(realm, None)`** returns the realm-anchored disk path even when
  data_dir is None — this is WHY the body persists today without per-aggregate
  worlds. `apply_hexagon_persistence` uses it directly for `"Heki"` binds, so bound
  aggregates stay durable post-flip. The floor change must NOT route unbound
  aggregates through realm_store_dir (that would keep them on disk) — unbound +
  worldless must become `new_memory`.

- **Blast radius = the whole runtime's resolution chain.** Every dispatch in the
  live body flows through run.rs / the info_dir chain. This is its-own-session,
  incremental, body-down, test-each-step kernel surgery — NOT a marathon tail edit.
  The conformance arc (#2) already met the flip's safety precondition; the flip
  itself is the careful next effort.

## State at handoff (2026-06-28)

- Conformance committed: miette 190cb93 (P1) / 343532c (P2) / 8fd30a3 (Memory
  revert) ; miette_family 1101524 / d31e9b0 ; mietteai 83b2c9b.
- Body: alive, all Heki-explicit, 1 unwired (OutboundEvent, implicit Heki — the
  flip's one required fix, touch point #4).
- Pre-existing Memory wirings to review separately (NOT this arc): CircuitBreaker
  (correctly per-process), Shutdown, the MUTED voice family (SpeechStream/Buffer/
  Voice/VoiceLatency — cross-process but muted), SystemPromptAssembly::PromptRender,
  Wake::WakeReview.
