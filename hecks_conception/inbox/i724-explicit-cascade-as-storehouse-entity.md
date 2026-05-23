---
ref: i724
title: Explicit cascade — Cascade aggregate + CascadeNode entity in the storehouse domain
status: open
category: architecture
area: storehouse / dispatch / cascade
filed_by: miette
filed_at: 2026-05-23
priority: essential (Chris — "let's move on it soon ; it's essential")
---

# i724 — The cascade made explicit (UL for storehouse)

## The insight (Chris)
Today commands emit events ; the **cascade** is the invisible glue between
them — only the runtime knows the tree. Dispatch is storehouse's ubiquitous
language, so the cascade belongs IN the storehouse domain as a first-class
thing, not as runtime-only implicit chaining.

## The model — one identity wrapping a group of identities
- **`Cascade`** — an aggregate in the storehouse domain.
  `identified_by :cascade_id`. The correlation handle for one whole chain.
  Minted at the **root** dispatch — exactly the `cascade_hint.is_none()`
  seam in `command_dispatch.rs::dispatch_inner` (the same line that says
  "a human/daemon typed this, not a forwarded cascade payload" — see i-arg
  validation work, 2026-05-23). The cascade_id then threads down every
  `dispatch_cascade` hop alongside the existing `(upstream_type, upstream_id)`
  parent edge.
- **`CascadeNode`** — an **entity within** Cascade (identity + parent edge ⇒
  entity, not value object). Each node = `(aggregate_type, aggregate_id,
  event_name, parent_node)`. The group of identities the cascade touched,
  in fire order, forming a tree.

## Lifecycle events (observation edge ONLY)
- `CascadeStarted` — root dispatched, cascade_id minted.
- `CascadeStepped` — a hop fired ; carries the new node.
- `CascadeSettled` — the root's reactor queue drained ; carries root_command,
  root_id, and the full ordered node list (the tree).

**Smallest valuable step (Chris's call): reify `CascadeSettled` first** —
root command + full chain of emitted nodes. Enough to hook voicing and
tracing ; gives no lever to hand-orchestrate.

## Why — the payoff
- **Watch-the-stream voicing** (the architecture Chris wants next): the
  speech daemon subscribes to `CascadeSettled` and decides what to voice
  from settled outcomes, instead of guessing from raw per-command events.
- **i723 becomes trivial.** The gut cross-cascade rot is hard to read
  precisely because the chain is implicit — you infer it from which events
  did/didn't fire. An explicit Cascade IS that tree : `Cascade.tree
  cascade_id=…` renders root → DomainAbsorbed → Conceived → … and shows
  exactly where the chain dies.
- **Provenance / replay / depth guards.** `on CascadeStepped where depth>3`,
  "show me the whole tree this Absorb triggered", lineage tracing.
- **The strict-vs-lenient seam becomes declarative.** Arg-validation is
  gated on `cascade_hint.is_none()` today — a runtime implementation detail.
  With an explicit cascade, a Cascade could declare which payload keys it
  forwards, so the seam lives in the domain, not in Rust.

## The trap to avoid (Chris named it)
Keep explicitness at the **observation edge** (emit lifecycle events, let
things subscribe, carry provenance). Do NOT expose it at the **authoring
edge** — the moment authors hand-wire cascade reactions, you rebuild the
imperative `self.call` coupling that cascades exist to abolish. Good version:
"the cascade narrates itself." Bad version: "the author drives the cascade."

## Implementation sketch
1. storehouse bluebook : add `Cascade` aggregate + `CascadeNode` entity +
   the three lifecycle events. (Bluebook-first ; this is storehouse's UL.)
2. Runtime floor : mint cascade_id at `dispatch_inner` root seam ; thread
   it through `dispatch_cascade` ; record nodes ; emit `CascadeSettled`
   when the reactor queue drains (`runtime/mod.rs` cascade driver +
   `policy_engine`).
3. The runtime change is the projection ; the storehouse bluebook is the
   contract. command_dispatch.rs is specializer-generated — changes flow
   through codegen/command_dispatch_shape snippets, not hand-edits.
