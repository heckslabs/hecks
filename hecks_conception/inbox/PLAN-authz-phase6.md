# PLAN — authz Phase 6 : the gate as a hexagon Family binding

*Working plan to resume after a context clear. 2026-06-29. Nothing built — this is the design,
grounded in the real code. Companion to `inbox/RESTART-authz-arc.md`,
`inbox/PLAN-authz-phase4.md`, and the 7-phase plan. Phase 4 is blocked on the roster ; Phase 5
is the gated kernel session ; this is the next phase buildable without either.*

## The asymmetry Phase 6 fixes
The `Storehouse::Gate` vision line says it: "Declared through the storehouse door via Gate.Declare
— no DSL, no hexagon form ... the inverse of a Driver : a Driver names its own inbound schedule
and runs out-of-process ; a Gate names its own inbound check and runs in-process, synchronous."
A **Driver already has a hexagon surface** (`driving on cron` in the .hecksagon). The **Gate does
not** — it is hand-authored through the door. Phase 6 gives the gate the symmetric authoring
surface so both halves of the boundary (inbound clock, inbound check) are declared the same way.

## What is already built (confirmed in code 2026-06-29)
- `Storehouse::Gate` (Declare/Retire/Active) : name, phase (before|after), check (verdict-key
  like "authorize"/"authenticate", OR a bluebook query Aggregate.Query), pattern, order, status.
- `rust/src/runtime/mod.rs::hydrate_middleware` ALREADY reads every active Gate record → the
  MiddlewareStack, and self-seeds `authorize` (order 20, before, pattern *) when none named
  authorize is declared. **So the Gate registry is ALREADY the projection the runtime consumes** —
  what is missing is the AUTHORING SURFACE above it.
- Four families exist (`aggregates/framework/families/`): persistence (persisted_by, REPLY,
  in-process), payment (charged_by, EFFECT, out-of-process), authentication (verified_by, EFFECT),
  screenshot_buffer.
- **Distinction that shapes the design:** `authentication.family` is `verified_by` / EFFECT — the
  once-per-session credential check at Establish. That is NOT the per-dispatch `authenticate`
  gate, which is IN-PROCESS, reply-shaped, reading the verdict that effect already recorded. So
  Phase 6's gate family is a NEW reply-signal family — a sibling of `persisted_by`, not `verified_by`.

## The design — two halves of very different risk

### Half A — tractable, declarative, NO parser change (safe in a normal session)
- A `gating.family` declaring verb `gated_by` (+ `authenticated_by`), `signal :reply`. Pure source
  vocabulary, like the other `.family` files — never flagged by the antibody.
- **`in_process` is DERIVED, not a new keyword** (design call) : `signal :reply` ALREADY means
  in-process / DI / inline per the two-color rule — it is why `persisted_by` is inline and the gate
  MUST be (it vetoes before the act, cannot await). So `in_process` is a property the gate inherits
  from its reply signal, not a marker to invent. (The plan's A3/A4 asked for an `in_process`
  marker ; recommend deriving it instead. Open for review.)
- Conceive the hexagon shape (`gating on dispatch` / `Aggregate.gated_by("authorize")`) in the
  chapter, DOCUMENTED but NOT yet wired — exactly how the Driver's `interval` sugar is
  conceived-but-not-parser-wired today (see pizzas.hecksagon comment).

### Half B — kernel / parity frontier (GATED, like Phase 5, NOT a normal session)
- The parser surface `gating on dispatch` that MINTS Gate records — `hydrate_middleware`'s comment
  literally calls this "a sibling kernel card." Adding a hexagon parse production touches
  `parse_blocks` / `hecksagon_parser` and the **Ruby↔Rust parity frontier** — the byte-precise,
  "design-judgment parity cannot verify" zone fenced off to its own fresh-head session.
- The projection wiring (hexagon source → Gate.Declare records → middleware), keeping `Gate.Declare`
  + the self-seeded `authorize` working untouched until it lands.

## The invariant (unchanged)
Nothing here touches `Principal::System => Ok(())` (first arm of authorize_check) or the
self-seed fallback in hydrate_middleware. `Gate.Declare` keeps working throughout ; the hexagon
surface is ADDITIVE until the projection is proven. Re-run the lockout check on the rebuilt binary
after any runtime touch (System admitted ; agent-no-permit denied).

## Recommendation
Build **Half A only** in a normal session : the `gating.family`, the `in_process`-is-derived
decision, and the conceived (unwired) hexagon chapter — bluebook-first, behaviors-green, no parser
touch, no parity risk. **Fence Half B as a gated sibling card** alongside Phase 5 — same kernel
frontier, does not belong in a high-context session.

## Build steps (Half A, once go is named)
1. `aggregates/framework/families/gating.family` — verb `gated_by` (+ `authenticated_by`),
   `signal :reply`. Mirror the persistence.family doc-comment shape.
2. Conceive the hexagon surface in the relevant grammar chapter (driving/hexagon sibling) :
   `gating on dispatch` block + `Aggregate.gated_by("authorize")` form, documented as
   conceived-not-wired (parser support is Half B).
3. Record the `in_process`-derived-from-reply decision in the chapter prose.
4. Behaviors green ; widened pre-push gate (152 .behaviors + cargo test --release + integrity).
   One commit. ff-only push HEAD:main.
5. File Half B as a gated kernel card (parser surface + projection), sibling to Phase 5.

## What is NOT in this phase
- No parser change, no parity-fixture touch (that is Half B / gated).
- No change to Gate.Declare, the self-seed, or the System-admit.
- No projection cutover (Half B).
