# An era is a stored projection, minted once per release

**Status:** Proposed. Date: 2026-11-01. The owner's rethink of eras, recorded before it is built.
Nothing below is a claim that it is done; the Status of the work section says what is true today,
what is in flight and what is not started.

## Context

An era makes two promises: stored rows stay readable under a known shape, and old code cannot write
into newer data. Everything else about eras (held text, edge files, minting, rehearsal, boot
status) is machinery serving those two promises.

The machinery has drifted from them. In the last days of October the repository met these faults:

- **The era's identity was stored twice and the two copies disagreed.** The era kept the domain's
  source text (`held_text`, the root file only) and the full projection the mint computed. For a
  domain split across files the text rebuilds a bluebook with none of the domain's aggregates, so a
  boot comparing the text's shape with the checkout's never matched.
- **Edges were written per hop.** Each shape change got an edge between two labels, so a chain of
  edges forked when two changes landed apart and went stale when a middle label was replaced.
- **Minting happened in two bad places:** at boot, and later inside the push's reaction chain,
  where it ran into the dispatcher's reaction depth limit.
- **Status tools read `shapes.json` instead of the database,** so a tool could say one thing while
  the database said another.

The incident that exposed it: Hecks eras 17 to 19 all hold shape `5d288c`, because each boot
minted a duplicate era. A four-edge stale route forked the mint. `Era.boot_status` answered
current while the boot itself refused. A `NameError` inside the mint surfaced as a null refusal
rather than a named fault.

## Decision

1. **Ask which data needs eras at all.** Hecks's own tooling records (the push-train runs, the QA
   ledger) are cheap to lose. If their shape moves, archive the old tables and start fresh. Eras
   are kept for client and production data.
2. **An era is a projection, not text.** Its identity is the stored projection and its hash. The
   source text is kept for audit only and decides nothing.
3. **Translate directly from the held era to the current shape, with no hops.** Edge files exist
   only for renames and conversions a diff cannot infer, and each is keyed by the change it
   describes, not by a pair of labels.
4. **Mint once per release, not once per shape change.** Decided by the owner on 2026-11-01. A
   shape change that is neither provably additive nor covered by a name-keyed rule is blocked at
   commit time: the gate fails when the change is made, so nothing that could lose data piles up
   on `main`. One mint per release (`release.mint`) then computes a single edge from the held
   era's stored projection to the current one. Its first step is making `MintDecision` and
   `Scaffold.diff` read the stored projection. The design is a study kept outside the repository
   and is not yet committed.
5. **Minting is a plain step before the push,** outside the reaction cascade. Boots stay
   read-only.
6. **One resolver everywhere.** Boot, status, rehearsal and mint call the same function against
   the database.

## Consequences

- A shape change to a tooling record costs an archive and a fresh table, not an edge and a mint.
  The people who lose history are the push train and the QA ledger, which the owner has judged
  acceptable; client and production data keep the full promise.
- Because text decides nothing, a domain split across any number of files has one identity, and
  the duplicate-era fault cannot recur from comparing text.
- Edge files shrink to the cases a diff cannot infer, and a stale label can no longer strand a
  chain, since there is no chain.
- Status, rehearsal, boot and mint cannot disagree, since they are one function reading one place.
- Retiring `shapes.json` as a source for status tools, and the existing hop-based edges, are
  migrations this decision implies and does not yet schedule.
- A mint outside the cascade is a separate step a person or the train must run; a push that skips
  it must be refused by name, not by a depth limit.

## Settled question

Point 4 had two readings: a mint per release, or a mint per push. The owner chose the release,
with the commit-time block above as the safeguard. The cost is that intermediate shapes never
exist as eras and cannot be rolled back to; the block is what makes that acceptable, since no
data-losing change reaches `main` unrecorded.

## Status of the work

Read from the repository on 2026-11-01.

**Already true.**

- Boots are read-only. They no longer mint (`f5c68b489`), and an unminted shape boots as
  unminted rather than superseded.
- A boot matches a held era by the projection the mint recorded (`98b1a0665`), falling back to
  the held text's shape only for an era minted without a projection.
- The push chain was shortened (`16ce91812`): the launcher refresh and deploy announcement react
  one step earlier, under the reaction depth limit.
- The mint decision and the rehearsal's edge decision go through one function (`2f0b27251`,
  `b7d77cb63`), and the Hecks domain's held era is minted before the push train writes
  (`6cdccb516`).

**In flight.** Other agents are building points 1, 2 and 3, 5 and 6 now, and the first step of point 4: a world setting that
makes a ledger disposable, decisions made from the stored projection, a sequential mint step, and
one resolver. This record states their intent only.

**Decided, not built.** Point 4. The design exists; its first step, making `MintDecision` and
`Scaffold.diff` read the stored projection, is in flight. The commit-time block and `release.mint`
are not started.
