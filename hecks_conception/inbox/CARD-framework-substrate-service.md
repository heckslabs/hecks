# CARD — framework substrate is an injected SERVICE, not a graft into the user's domain

**Decided with Chris, 2026-07-19.** Design LOCKED below.

> **STEP ZERO IS DONE — `1e49c0ef4`.** Both risks that could have killed this
> card are resolved. The BORROW SHAPE works : `record_event_append` runs inside
> `&mut self` and calls the collaborator cleanly, because `heki_path()` returns
> an owned String so the store-dir borrow ends before the per-delta dispatch
> re-borrows. Zero borrow errors, first compile. The BEHAVIORS CORPUS stays
> green (152/152) because the collaborator boots LAZILY and the corpus never
> appends an Event.
>
> Shipped : `Runtime.framework: Option<Box<Runtime>>`, `framework_mut()`,
> `EVENT_SOURCING_SUBSTRATE` bundled at `rust/resources/`, and
> `record_event_append` routing into the collaborator. A single-bluebook boot
> carrying `event_sourced` now writes its Log — the case that silently wrote
> NOTHING before.
>
> Unplanned property worth keeping : the collaborator inherits `data_dir`, so
> existing readers of `rt.all_qualified(Some("EventSourcing"), "Event")` still
> see the Log (the parent's lazy repo hydrates from the same store). Verified by
> MUTATION — neutering the collaborator's Append fails both the new proof and
> slice 1's, so nothing passes by luck.
>
> GOVERNANCE DONE — `8045e5b2e`. A denied dispatch now always leaves an audit
> row ; `authorize_pdp_test` had been asserting denials that recorded nothing.
>
> REMAINING : **OutboundEvent only** (CascadeRun is out of scope — see the
> CORRECTION at the top). And it is NOT the simple repetition this card
> originally assumed. Scoped on 2026-07-19 :
>
> - Only ONE lifecycle dispatch carries an FQN (`mod.rs:2007`, Record). `Claim`
>   / `MarkDelivered` / `MarkFailed` are dispatched by SHORT NAME from
>   `run_host` and from the pump/drain, so they resolve against whichever
>   runtime is being dispatched into — all of them need re-addressing.
> - The consumers straddle BOTH runtimes : `Claim` / `MarkDelivered` must land
>   in the COLLABORATOR while the verdict commands (`Order.Authorize` /
>   `Order.Decline`) must land in the PARENT. Today both are `self`.
> - `run_host` is a SEPARATE PROGRAM that boots its own runtime and reads the
>   outbox off disk. It would need the collaborator too, and `framework_mut()`
>   is currently private.
> - `AllPending` (slice 2, `0bd076d20`) is queried on the parent and moves.
> - Only then can `ensure_outbox_substrate`, its predicate, the 2026-07-19
>   scoping fix, and `outbox_graft_scope_test` be deleted.
>
> This is the LOWEST-urgency of the three : unlike EventSourcing and Governance,
> the outbox's coupling is already PATCHED by the graft, so nothing is silently
> lost today. It is a real refactor deserving a fresh head, not a repeat.
>
> Decision 4 (one framework-realm store) is NOT yet implemented : step zero
> inherits the parent's `data_dir`, which is what keeps temp-dir tests isolated.
> Moving the durable home to the framework realm is a follow-up and was never a
> borrow-shape question.
Supersedes the deferred "should framework substrate be injected at boot?"
question raised at the close of the outbox-as-event-sourcing arc.

## BLOCKER 2026-07-19 — the outbox CANNOT move until its store is canonical

The outbox move was BUILT and is green on unit tests (124/124), parity
(400/400) and behaviors — then **blocked by `dream_content_smoke`**, which the
unit suite structurally could not catch. Preserved on the local branch
`wip/outbox-collaborator` (`f12a42e57`) ; main stays at the working state.

**Why the outbox is different from the other two.** EventSourcing and
Governance moved cleanly because their consumers are all IN-PROCESS. The outbox
is the one substrate with OUT-OF-PROCESS readers :

- the generic adapter-host (`bin/adapter-host`) drains it as a separate program
- `dream_content_smoke` reads it via a separate CLI process :
  `storehouse query <root> OutboundEvent::OutboundEvent.pending adapter=DreamImage`

Those readers resolve the **corpus** OutboundEvent store — which carries its own
`outbound_event.world` with `dir :default`, a FOLDER-DERIVED location — while
the collaborator is booted through `boot_with_data_dir` and writes plain
`data_dir`. Writer and reader diverge, so a recorded delivery is invisible
off-process and the `:dream_image` adapter never fires. Symptom :
`WARN : run-loop recorded no DreamImage outbox`.

**This is CARD decision 4 turning out to be LOAD-BEARING.** "One framework-realm
store" was filed as a follow-up and explicitly deferred at step zero as "not a
borrow-shape question". True — but it IS the outbox question. The collaborator's
store location must be canonical AND discoverable by an out-of-process reader
before the outbox can move.

Note the awkward wrinkle : `heki::folder_address` derives the realm from the
repo directory name (`hecks`), so "anchor the collaborator to the framework
realm" cannot be done by hardcoding a realm string into the kernel without
baking a repo name into it. That is the design question to answer first.

**Lesson recorded** : the unit suite passed at every step of this move. Only a
smoke test that crosses a PROCESS boundary could see the divergence, because
the bug is about where two processes each think the store lives. In-process
tests cannot express it.

## CORRECTION 2026-07-19 — it is THREE substrates, not four

This card originally said "four substrates, seven guard sites, one shape". That
was right about the SHAPE of the guard and WRONG to conclude all four should
move. Investigated when moving CascadeRun ; the guards split two ways :

- **EventSourcing / Governance / OutboundEvent** — the guard selects between
  WORKING and LOSING DATA. No Log, no audit row, no delivery record.
- **CascadeRun** — the guard selects between TWO WORKING PATHS. Without it,
  reactions go to the IN-MEMORY outbox (`self.outbox`) delivered by `pump()`
  instead of the persistent one delivered by `pump_outbox()`. Both settle
  in-process before dispatch returns. `mod.rs:1204` states the equivalence
  outright : "Roots without the CascadeRun outbox fall back to the in-memory
  pump (== the prior synchronous react), so behaviour is preserved there."

**CascadeRun should NOT move.** Moving it would switch every runtime from the
in-memory path to the persistent one — disk writes on every cascading dispatch,
changed ordering, test-expectation churn — for zero correctness gain. Its guard
is a legitimate strategy switch, not a silent failure.

### A hypothesis tested and REJECTED

Before moving CascadeRun I suspected a latent bug : `serve_directory` gives
EVERY served runtime the same `<dir>/data` (`multi.rs:317`), CascadeRun carries
no domain discriminator, and `pump_outbox` filters only on
`status == "running"` — so domain A's pump looked able to drain domain B's runs.
**Probed with two runtimes sharing a data dir : NOT reproduced.** `dispatch`
pumps to quiescence synchronously, so a run is `completed` before any sibling
could see it. Recorded here so nobody re-derives the same suspicion. (A run
stranded Active by a crash mid-pump, or a second PROCESS on the same data dir,
is still theoretically exposed — speculative, unproven, not blocking.)

## The bug, stated once

The runtime needs to dispatch into framework aggregates it does not own. Today
it does this by **hoping the framework aggregate was merged into the user's
domain**, and silently doing nothing when it wasn't. Four substrates, seven
guard sites, all the same sentence :

| substrate | guard sites |
|---|---|
| `EventSourcing::Event` | `mod.rs:1363` |
| `CascadeRun` | `mod.rs:1661`, `reaction.rs:169` |
| `OutboundEvent` | `mod.rs:1798`, `mod.rs:3131`, `reaction.rs:325` |
| `Governance::Violation` | `mod.rs:689` |

```rust
if !self.domain.aggregates.iter().any(|a| a.name == "CascadeRun") { return; }
if !self.repositories.contains_key(&es_key)                       { return; }
```

`ensure_outbox_substrate` is a MANUAL PATCH for exactly one of the four : it
merges the outbox bluebook into any domain with an effect port, so the
`OutboundEvent` guards pass. The other three have no patch and simply degrade.

Severity is not uniform, and the outbox is the LEAST severe :
- **Governance** is the worst — an authorization denial loses its audit row on a
  minimal runtime. Documented in-source as acceptable ("the denial still stands
  — we just don't get an audit row"). A security property contingent on which
  bluebooks happened to be merged.
- **EventSourcing** silently writes NO Log. Felt directly on 2026-07-19 : slice
  1's proof had to assemble a corpus and copy the EventSourcing chapter in just
  to make the Log write. That was read as test setup ; it was a symptom.
- **OutboundEvent** at least announced itself — as a stray module on ToolShed's
  served page, which is what opened this whole arc.

## Evidence this is a pattern, not a coincidence

Four distinct substrates, seven sites, one shape. The graft's own predicate had
to be narrowed on 2026-07-19 (`50b3b8db7`) because "does ANY attached hecksagon
carry an effect binding?" grafted the outbox onto every served domain —
`serve_directory` loads every hecksagon in the repo. Patching one of four
coupling sites produced a subtle predicate that then needed its own two-
direction regression test. That is the cost of the workaround, not of the
problem.

## LOCKED decisions

**1. Mechanism — ONE framework collaborator, not four.**
The runtime holds a single collaborator booted on framework substrate, injected
at boot exactly as the persistence adapter is. Not four separately-booted
services : four boots, four stores, four times the wiring, for one mechanism.

**2. Surface — per-concern service facades over that one collaborator.**
`EventSourcingService`, `OutboxService`, `CascadeService`, `GovernanceService`.
Each names what the kernel needs (`append_event`, `record_delivery`,
`pending_deliveries`, `record_violation`) so call sites read as intent rather
than as dispatch plumbing. Chris's naming instinct, one collaborator underneath.

**3. It follows `FrameworkRegistry`, it does not extend it.**
`runtime/framework_registry.rs` is about ADAPTER FAMILIES and BEHAVIOR KINDS —
routing dispatch to native kernel hooks (claude_tool, mcp, web_tool). It is NOT
substrate. Checked, 2026-07-19, after twice gesturing at the name without
reading it. It is the PRECEDENT for the shape (typed registry, built at boot,
looked into by the runtime) and nothing more.

**4. Data layout — ONE framework store, in the framework realm.**
Settled by evidence, not preference. `heki::realm_store_dir` anchors a store on
the aggregate's realm, so a CORPUS boot already writes `OutboundEvent` under the
framework realm. Per-domain outbox storage happens only because the GRAFTED
copy is parsed from a crate resource carrying no `realm_path`, so it falls back
to the served domain's data dir. Per-domain storage is an artifact of the graft,
not a design. A host drains by ADAPTER, never by domain, so one outbox per
process is also the truthful model.

**5. The collaborator owns the substrate bluebooks.**
This retires the two-copy tax (`rust/resources/outbound_event.bluebook` vs the
conception copy, guarded by `outbox_substrate_parity_test`). Hit on 2026-07-19 :
editing one copy turned seven tests red until the other was mirrored. The gate
worked ; the drift class should not exist.

**6. Order — EventSourcing first.**
It has the clearest consumer (`record_event_append`), the sharpest existing
proof (`event_sourced_outbox_log_test`, `cf274e2d7`), and no served-UI entangle-
ment. Then OutboundEvent, then CascadeRun, then Governance. One green gated
commit each.

## What this DELETES

- `ensure_outbox_substrate` + its call site (`mod.rs:373`)
- the `has_effect` predicate and its 2026-07-19 scoping fix
- all seven substrate-presence guards
- `outbox_substrate_parity_test` and the second copy it guards

Net kernel SHRINK, which matters : `core_runtime` is a shrink concern and this
arc has already spent two `[loc-ratchet-override]`s.

## Risks / what could still kill this

- **`Runtime` has no sibling-runtime concept.** The
  `HashMap<String, RefCell<Runtime>>` lives in the SERVER layer
  (`server/multi.rs`), not in `Runtime`. Giving the runtime a collaborator it
  can dispatch into is a real kernel change and the largest unknown here. Not
  costed.
- **Borrow shape.** `record_event_append` / `record_effect_outbound` run inside
  `&mut self` dispatch. A collaborator called from there must not require a
  second mutable borrow of the parent runtime. Likely fine (the collaborator
  owns its own state) but unproven.
- **Slice 2 rework.** `AllPending` (`0bd076d20`) is currently queried on the
  user runtime. It would move to the collaborator — the declared query survives,
  its address changes.
- **Behaviors corpus.** 152 `.behaviors` files boot through
  `boot_in_memory_with_hecksagons`. The collaborator must be present and
  memory-backed there, or the corpus goes red wholesale.

## Step zero

Prove the collaborator can be called from inside `&mut self` dispatch, with
`EventSourcing::Event.Append` as the one consumer, on a SINGLE-bluebook boot
that carries no EventSourcing chapter — the case that silently writes no Log
today. If that lands green, the shape is real and the rest is repetition. If the
borrow shape fights it, this card is wrong and should be reopened rather than
forced.
