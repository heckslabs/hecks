# A translation edge declares its own rollback

**Status:** Proposed. Date: 2026-10-02. Builds on [ADR 0033](0033-eras-become-a-loadable-persistence-plugin.md) (eras) and [ADR 0082](0082-the-two-translation-chapters-become-one.md) (one Translation chapter).

## Context

A mint that changes a domain's shape cannot be undone today.

- One append-only journal per domain holds every era. Each row carries an `era` column, and a mint creates that era's partition, its per-aggregate lineage views and head snapshots, and then recreates the unqualified `<aggregate>_head` view so it points at the newest era (`rust/host/src/mint.rs`).
- The write fence moves with the head: row-level security accepts only `era = N`. An image built for an older era that boots against a newer head finds its own era, serves it (`decide_boot_action`, `UseExisting`), then has every write refused by the fence and every read answered from the head view, which has the newer shape. The Ruby runtime has an explicit read-only mode for a superseded era (`PostgresEra#refuse_superseded_write!`); the Rust host has none.
- An edge is forward only. The rule kinds are rename, move, convert, drop, retype, compute, rekey and backfill, compiled by `translation/rule_compiler.rb` and `lineage.rb` and re-read by the host (`parse_edges`). Nothing declares how to go back, and several kinds cannot be inverted mechanically: a drop loses values, a compute loses its inputs' provenance, a backfill overwrites nulls, a rekey needs its mapping, a narrowing retype loses range.
- A database snapshot restore is the only recovery. It discards every write since the snapshot and, on a cluster shared by many domains, rolls all of them back.

## Decision

An edge may declare its own rollback, and the tooling treats the declaration as the unit of reversibility.

1. **Authored, never inferred.** Each rule kind accepts a `rollback` clause stating how to restore what the forward rule changed: the inverse rename, the default for a dropped field, the mapping table for a rekey. A kind that cannot be inverted without more information must carry either a `rollback` or `irreversible`. A rename, and a move or convert with a one-to-one value table, are reversible without authoring.
2. **Irreversible is an answer.** An edge marked `irreversible` can only be rolled forward. Tooling reads that as "a person decides", and says so.
3. **A rollback is an era.** Rolling back mints era N+1 with the earlier shape and the reverse edge, and rolling forward again mints N+2 with the later shape and the forward edge. Eras only grow, no ordinal is reused, and the existing audit, approval digest, watermark and tail merge apply to each step unchanged.
4. **The audit checks it.** The pre-mint audit already tracks dropped and unfed paths. It also verifies that every new edge declares a rollback or `irreversible`, and that for each declared rollback a forward, back, forward round trip on fixture data reproduces the original.
5. **The approval digest covers it.** Rollback rules are folded into the digest the way rekeys and backfills are, so they are reviewed with the forward rules.
6. **A gate reports it.** A diff of two bluebook releases lists the edges the change adds and whether every one is reversible. A deploy pipeline can auto-deploy a change only when all are, and otherwise leaves the deploy to a person.

The work lands in two stages.

- **Stage 1 declares and audits.** The DSL clause, the IR fields, the audit, the digest and the gate. The host reads the new IR fields and ignores them at runtime, so no running behavior changes.
- **Stage 2 executes.** The Rust host gets an explicit read-only mode for a superseded era, a reverse of the chain SQL in both runtimes, the N+1 mint, and a way to flatten old chains. This stage waits for a prototype: a small domain with one reversible and one lossy edge, run forward, back and forward on both runtimes, checking that no row is lost or duplicated.

## Consequences

- The IR gains rollback fields on each edge, and the approval digest changes with them. Edges already minted are grandfathered as undeclared, which the gate reads as "a person decides". New edges must declare.
- The Translation chapter from ADR 0082 owns the clause: `Rule` declares which kinds accept `rollback`, and a kind is admitted only when its rollback also executes in two targets.
- A lossy edge costs its author a decision at write time instead of a recovery at deploy time.
- Chain length keeps growing with each era, and boot replays the chain. Flattening old chains past rollback range is part of stage 2.
- Not in this decision: restoring a single tenant's schema, canary rollouts, and letting an older image that is declared compatible write at the head era. Each is a separate change.
