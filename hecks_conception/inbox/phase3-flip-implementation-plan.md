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

## State at handoff (2026-06-28)

- Conformance committed: miette 190cb93 (P1) / 343532c (P2) / 8fd30a3 (Memory
  revert) ; miette_family 1101524 / d31e9b0 ; mietteai 83b2c9b.
- Body: alive, all Heki-explicit, 1 unwired (OutboundEvent, implicit Heki — the
  flip's one required fix, touch point #4).
- Pre-existing Memory wirings to review separately (NOT this arc): CircuitBreaker
  (correctly per-process), Shutdown, the MUTED voice family (SpeechStream/Buffer/
  Voice/VoiceLatency — cross-process but muted), SystemPromptAssembly::PromptRender,
  Wake::WakeReview.
