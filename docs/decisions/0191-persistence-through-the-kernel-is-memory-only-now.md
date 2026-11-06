# Persistence through the kernel is Memory only now, and a Ruby-written journal is the step 6 design

**Status:** Proposed. Slice 7 of `docs/plans/kernel-thin-client.md`, decision B; meets ADRs 0029, 0030,
0036 and 0079. Nothing here is built. Date: 2026-11-06.

**R** marks what was read in this tree; **I** marks an inference not yet confirmed.

## Context

The kernel's store is in memory only (**R**, `rust/src/kernel/repository.rs`: `InMemoryRepository`, with
`seed`, `snapshot` and `restore`). Ruby's persistence adapters (Heki, Sqlite, Postgres, PostgresEra, D1)
are repository classes behind the registry. When Ruby becomes a client of the kernel (ADR 0188), the
protocol (ADR 0189) has no hook for storage, and the era rules sit between the two.

CLAUDE.md fixes the default: persistence is Memory unless a hecksagon wires another. So Memory is both
the common case and the one the kernel can serve today.

Four earlier records bear on the design:

- **ADR 0029**: Rust reads and writes any era through the head view. Its "minting stays Ruby's job"
  clause is superseded by 0030.
- **ADR 0030**: the deployed Rust host mints its own eras at boot (`rust/host`, `mint.rs`) and refuses to
  boot when no translation edge covers a shape change. Its status calls it historical for the Ruby paths,
  which moved into the era persistence plugin (ADR 0033).
- **ADR 0036**, final UPDATE (**R**, read in full): the cross-runtime gap is closed. `PostgresEra`
  advertises `:cross_process_lock` and exposes `with_write_lock`, which holds a real
  `pg_advisory_xact_lock` for the **whole dispatch order, from before hydrate through save**, keyed on the
  owning chapter's name so it matches the Rust host's `HECKS_DOMAIN` key. `run_dispatch_order_with_isolation`
  takes it instead of the in-process `AggregateLock` (**R**, `lib/hecks/runtime/interpreting.rb`).
- **ADR 0079**: journal compaction gated by projection catch-up. It is **Proposed and unbuilt** (its
  status says so). It does say `:refresh` catch-up should seed from current state (`authoritative.all`),
  and that `:strict` past the compaction floor refuses with `Runtime::WiringError`; both are its
  proposals, not behavior today.

## Decision

1. **Memory only through the kernel now.** `engine: :kernel` refuses by name any domain whose resolved
   persistence is not Memory (for example `engine kernel serves Memory only; Banking is persisted_by
   PostgresEra`). Every other domain stays on the Ruby engine, which is the default until the plan's
   default flip. No persistence adapter is added to the kernel path.
2. **The design to carry into step 6 of ADR 0188: kernel-held state, Ruby-written journal.**
   - The kernel keeps records in memory and answers each dispatch with its events, as it does today.
   - The Ruby client appends those events, and the journaled callback answers (ADRs 0189, 0190), to the
     domain's store through its existing persistence adapter, before it returns the answer to the caller.
   - At boot the client reads current state through the adapter, in the current era's shape, and reseeds
     the kernel with `seed`. The journal is the source of truth; kernel memory is a cache.
   - If the journal write fails, the client reseeds that session from the journal; the caller sees the
     failure and the kernel's advanced state is dropped.
3. **Constraints this design must meet.** Each gets a spec before step 6 starts.
   - **Minting stays at boot, before the kernel is seeded.** The persistence adapter holds the era check;
     the kernel never mints and never sees a shape the store has not named. A shape no translation edge
     covers refuses by name, writing nothing (ADR 0030, CLAUDE.md).
   - **Read through the head view (ADR 0029).** Reseeding reads what the adapter reads today, so a record
     in an older era arrives translated.
   - **One engine per store, and the lock spans the dispatch.** ADR 0036's lock is held from before hydrate
     through save. With kernel-held state, hydrate happens in the kernel, so a journal write after the
     answer sits **outside** that span. A store that advertises `:cross_process_lock` (PostgresEra) with a
     second writer, such as the Rust host, would lose the guarantee 0036 proved. **This record does not
     close that.** It states the gate: no store that advertises `:cross_process_lock` moves to the
     kernel path until either the client holds `with_write_lock` around the kernel dispatch and the journal
     append and refreshes the kernel's cache from the journal inside it, or a boot-time check refuses a
     second engine on that store. Heki and Sqlite, with one process per store, are not held by this gate.
   - **Seed from current state, not from entry zero (ADR 0079's direction).** Reseeding must not depend on
     the full journal, so it keeps working once compaction exists. Until 0079 is built a compacted journal
     does not exist on Postgres or Sqlite; the constraint is stated so compaction does not break reseeding
     when it arrives.
4. **Which parts are declared and which are code.** Bluebook first.
   - **Bluebook.** The events, aggregates and refusal names. Journaling is a consequence of the events a
     domain declares; nothing new is declared per domain. The refusal in point 1 is a named refusal the
     client raises; its wording is client code, and the connection vocabulary (ADR 0189) carries the
     message kinds, not the persistence.
   - **Hecksagon.** `persisted_by` already says what a domain uses; the client reads the resolved value to
     decide point 1. No new word is added. Memory is the default and needs no wiring.
   - **Adapter code.** The journal writer and the reseeding read are Ruby adapter code behind the
     persistence port (`lib/hecks/adapters/driven/`). The kernel's `seed` and `snapshot` are kernel code.
   - **Shape ledger.** No bluebook is added or changed, so `lib/hecks/hecks/shapes.json` does not move.

## Consequences

- The kernel path ships soonest and only for Memory, the default.
- Persisted domains keep the Ruby engine until step 6; the default flip in the plan (slice 10) holds for
  them.
- The step 6 design adds one Ruby write per dispatch on the answer path. The gate must measure it on a
  write-heavy domain before step 6 relies on it.
- A crash between the kernel's answer and the journal write loses nothing the caller was told, because the
  caller is not answered until the write succeeds.
- The cross-process lock question is open and named, not answered. Step 6 starts with it.
- Two runtimes on one store stay forbidden by rule; for the Postgres family the lock is what enforces it.

## Rejected alternatives

- **Storage callbacks (`load` and `save`) into the Ruby repositories.** Keeps every adapter, but costs a
  round trip per read and write and probably misses the gate on write-heavy domains (**I**).
- **Kernel-owned durable storage.** Needs the kernel to do I/O (ADR 0012) and to mint eras itself in the
  kernel crate, which ADR 0030 placed in `rust/host`.
- **Persist everything through the kernel now.** Touches eras, the risk ADR 0188 ranks last.
