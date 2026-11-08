# Persistence through the kernel is Memory only now

**Status:** Proposed. Slice 7 of `docs/plans/kernel-thin-client.md`, decision B. Nothing here is built.
Date: 2026-11-06.

**R** marks what was read in this tree; **I** marks an inference not yet confirmed.

## Context

The kernel's store is in memory only (**R**, `rust/src/kernel/repository.rs`: `InMemoryRepository`, with
`seed`, `snapshot` and `restore`). Ruby's persistence adapters (Heki, Sqlite, Postgres, PostgresEra, D1)
are repository classes behind the registry. CLAUDE.md fixes the default: persistence is Memory unless a
hecksagon wires another. So Memory is both the common case and the one the kernel can serve today.

## Decision

1. **The kernel refuses any domain that is not Memory, by name.** `engine: :kernel` refuses a domain whose
   resolved persistence is not Memory (for example `engine kernel serves Memory only; Banking is
   persisted_by PostgresEra`). Every other domain stays on the Ruby engine, which is the default until the
   plan's default flip. No persistence adapter is added to the kernel path, and no journal is written
   through it.

That is the whole decision. Nothing else is decided here.

### Which parts are declared and which are code

Bluebook first, then hecksagon.

- **Bluebook.** The refusal is a named refusal the engine choice raises. No aggregate, event or command is
  added, so `lib/hecks/hecks/shapes.json` does not move.
- **Hecksagon.** `persisted_by` already says what a domain uses; the engine reads the resolved value to
  decide. No word is added. Memory is the default and needs no wiring.
- **Adapter code.** The check sits in the engine choice, which is Ruby client code.

## Open question for step 6 of ADR 0188: how a persisted domain reaches the kernel

Not decided here. One design was drafted and is kept only as a starting point (**I**): kernel-held state
with a Ruby-written journal, where the client appends each dispatch's events through the domain's existing
persistence adapter before answering, and reseeds the kernel from the store at boot. Step 6 must settle
these three before it relies on any design, each against the record that owns it:

- **Where minting lives, against ADR 0030** (`0030-rust-mints-its-own-eras-at-boot`). 0030 puts minting in
  the Rust host (`rust/host`, `mint.rs`), which refuses to boot when no translation edge covers a shape
  change. A Ruby-written journal needs the era check before the kernel is seeded, which is a Ruby-side
  mint and so reopens 0030. The question is which one owns minting for a kernel-served persisted domain,
  and what a shape no edge covers does then (it must still refuse by name, writing nothing). ADR 0029's
  head-view read applies to whichever it is.
- **The advisory lock key, against ADR 0036.** 0036 holds `pg_advisory_xact_lock` across the whole
  dispatch order, from before hydrate through save, keyed on the owning chapter's name to match the Rust
  host's `HECKS_DOMAIN` key (**R**, 0036's final UPDATE). With kernel-held state, hydrate happens in the
  kernel and a journal append after the answer falls outside that span. The question is whether the
  client holds `with_write_lock` around dispatch and append, or a boot-time check refuses a second
  engine on the store, and which key it takes. The Rust host's real key derivation was not read (**I**).
  No store advertising `:cross_process_lock` moves to the kernel path before this is answered.
- **The compaction floor, against ADR 0079.** 0079 (journal compaction gated by projection catch-up) is
  Proposed and unbuilt. Reseeding must not need the full journal, so it reads current state rather than
  entry zero, and must meet the floor 0079 sets (`:strict` past it refuses with `Runtime::WiringError`;
  `:refresh` seeds from current state). The question is the floor a kernel reseed is held to.

## Consequences

- The kernel path ships soonest and only for Memory, the default.
- Persisted domains keep the Ruby engine until step 6; the default flip in the plan (slice 10) holds for
  them.
- Two runtimes on one store stay forbidden by rule; the refusal keeps the kernel off every store.
- Step 6 starts with the three questions above, not with a design.

## Rejected alternatives

- **A Ruby-written journal now.** Needs the three answers above first; it was the draft of this record and
  the architect's review asked for it to be cut back.
- **Storage callbacks (`load` and `save`) into the Ruby repositories.** Keeps every adapter, but costs a
  round trip per read and write and probably misses the gate on write-heavy domains (**I**).
- **Kernel-owned durable storage.** Needs the kernel to do I/O (ADR 0012) and to mint eras itself in the
  kernel crate, which ADR 0030 placed in `rust/host`.
- **Persist everything through the kernel now.** Touches eras, the risk ADR 0188 ranks last.
