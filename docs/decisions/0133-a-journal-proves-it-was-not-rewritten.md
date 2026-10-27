# A journal proves it was not rewritten

**Status:** Accepted. Built: the Ledger chapter (`lib/hecks/hecks/ledger.bluebook`), its adapter
(`lib/hecks/hecks/adapters/ledger.rb`) and the Rust host's seals (`rust/host/src/ledger.rs`).
On local `main`, not released. Date: 2026-10-26.

## Context

A Hecks journal is append-only by construction, and the Postgres era journal is append-only by
permission as well: row-level security refuses an update or a delete from the application role.
Nothing, though, said afterwards that the journal still held what it held. A superuser, a backup
restored by hand, or a disk edit could change a row, drop one or reorder two, and every reader
would take the result as the history. Compaction (ADR 0079) is the one sanctioned way rows leave a
journal, and it removed them with no record of what the journal looked like before.

This came up as a request for a "cryptographic ledger plugin" hooked into a microkernel with
pre- and post-execution hooks. Hecks has no such kernel and should not: cross-cutting behaviour
is declared (givens, invariants, policies, properties) so `model_check` and the behaviors can see
it, and the Rust kernel is deterministic and dependency-free so three runtimes can be diffed. The
need underneath the request was real and narrower: a way to show a journal was not rewritten.

Eras already protect the bluebook text of each era with a hash (`hecks_eras.hash`). They do not
protect the rows.

## Decision

Every decision says which side it is on.

1. **Bluebook: a `Seal` is a record, an `Audit` is a walk.** The Ledger chapter adds two
   aggregates to the Hecks chapter. `Seal` holds the head a domain's journal chain had through an
   ordinal, and the head of the seal before it, so seals chain too; the first follows the genesis
   digest, sixty-four zeros. `Audit` is one walk of a domain's chain from its seals, with a
   lifecycle `requested -> verified | unproven`. `unproven` is the only failure, whether a digest
   did not hold or the walk could not run; the report names the row or the reason. A chain that
   cannot be shown intact is not called tampered.

2. **Bluebook: compaction seals first.** `Era.EraPermitted` for a `compact` or `compact_heki`
   operation triggers `Era::Ledger::Capture`; `Era::JournalStore::Apply` waits for
   `Era.HeadCaptured`, and `Era.CaptureRefused` abandons the change. The capture is one ask on the
   `Era` being changed, because the reaction depth is bounded at five in both runtimes and the
   compaction chain already uses four. A compaction whose head cannot be captured is abandoned,
   never applied.

3. **Hecksagon: `Ledger` is a port, asked by `Era` and by `Audit`.** `hecks.hecksagon` declares
   `Capture` (answers `HeadCaptured`, refuses `CaptureRefused`) and `Walk` (answers
   `ChainWalked`, refuses `WalkRefused`). The adapter is `Hecks::Adapters::Ledger`.

4. **Adapter: seals live beside the journal they cover.** A persistence adapter whose journal can
   be chained answers `ledger_anchors` and `record_ledger_anchor`: an `.anchors` file of JSON
   lines next to a Heki journal, a `hecks_ledger_anchors` table (`aggregate_table`,
   `through_sequence`, `head`, `previous`, `sealed_at`) next to a Sqlite or Postgres one. Sealing a
   point twice with the same head changes nothing; a different head for a sealed point is refused,
   never overwritten. A journal that cannot keep seals (Memory) is left out. Seals stored apart from
   the journal, in the Hecks records, were rejected: a compaction could then take the evidence of
   what it removed along with it, and the `Walk` adapter would need a second connection to read
   them.

5. **Adapter: the digest rule is the same in Ruby and Rust.** Each digest takes the digest before
   it, then the entry's `operation`, `id`, `state` and `mirrors`, each length-prefixed so two
   entries never pack to the same bytes. `state` goes in as the state codec's JSON in Ruby and as
   the stored `jsonb` text in the host, where an absent value is distinguished from an empty one.
   The ordinal, the era and the time are not hashed: the ordinal only orders the walk.

6. **Host: the Rust host seals the era journal, inside its own commits.** Ruby's adapter leaves the
   era journal out, since row-level security already fences it; the host seals it anyway, because a
   seal is evidence against someone the database does not stop. `ledger seal <Domain>` and
   `ledger verify <Domain>` are operator tools. A commit also seals on its own: once
   `LineageConfig.seal_every` rows (a thousand unless `HECKS_SEAL_EVERY` says otherwise, `0` to
   turn it off) lie past the last seal, `ledger::seal_due` folds them and writes the seal in the
   same transaction as the rows it covers, under the domain's write lock it already holds. The
   seal and its rows land together or not at all, and the one dispatch in every N pays for hashing
   those N rows. The interval counts rows, not commands, because the chain covers rows.

7. **Not a plugin trait, not a budget.** The pre- and post-execution hook, the token quota and the
   step budget of the original request were dropped. The host already bounds every kernel run (a
   deadline, a memory cap, an output cap, an argument cap) and the orchestrator bounds reaction
   depth; a token quota belongs to whatever agent calls Hecks, not inside it.

## Consequences

- A domain on Heki, Sqlite or Postgres can show, from its own files or tables, that its journals
  hold what they held when last sealed. A domain on the Rust host over Postgres can show the same
  for its era journal, and a running host keeps that true to within `seal_every` rows without an
  operator doing anything.
- The rows between the last seal and the end of a journal are reported as unsealed, not as
  intact. A verify before a deploy or an audit should seal first.
- Once compaction has removed the rows a seal covers, a walk can check only that the seals still
  follow one another; the rows are gone, so the head is taken on trust from the seal. The seal
  records what was there; it cannot bring it back.
- A seal proves integrity, not authorship. The host's command journal (verb and arguments, the
  one a replay reads) is not sealed, and no row carries who ran the command or when. Those are
  separate gaps, named here so they are not mistaken for something this record covers.
- A seal taken on commit adds a read of up to N rows and their hashing to one dispatch in N. At
  the default it is a few milliseconds every thousand rows. A domain that writes many lineage rows
  per command sees the seal sooner, not later.
- The Hecks storage shape moved (`f53248` to `148748`) for the `Seal` and `Audit` records, covered
  by an additive translation edge; no era was minted.
- The Ruby adapters seal a sequenced journal only up to its projection checkpoint, the point
  compaction deletes through, so a seal never covers an entry a projection has not seen.

## Rejected alternatives

- **A microkernel with plugin hooks.** Undeclared imperative middleware around dispatch, built
  twice and kept in parity by hand, invisible to `model_check`. The Rust kernel's value is that it
  is small, deterministic and free of I/O; a hook with dynamic adapters and a clock would end that.
- **Per-row digest columns on the journals.** A stored-shape change to every partitioned era
  journal and its views, needing an era mint and a translation edge on every domain, for no more
  evidence than a seal beside the journal gives.
- **Seals in the Hecks records database.** Rejected under decision 4.
- **Sealing on a clock.** A scheduled `ledger seal` leaves an unbounded tail between runs and needs
  something to run it. Sealing on commit bounds the tail by rows and needs nothing.
- **Counting commands instead of rows.** A command can write zero or several lineage rows; counting
  rows keeps "at most N rows unsealed" true.
