# CARD — framework substrate is an injected SERVICE, not a graft into the user's domain

**Decided with Chris, 2026-07-19.** Design LOCKED below ; no code written yet.
Supersedes the deferred "should framework substrate be injected at boot?"
question raised at the close of the outbox-as-event-sourcing arc.

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
