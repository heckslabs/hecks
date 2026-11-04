# One Postgres adapter picks its layout from the hecksagon

**Status:** Proposed. Date: 2026-11-04. Owner: to be decided. Not yet built.

## Context

Revision support (era support, renamed in the 8.0 change list) lives in a second adapter,
`PostgresEra` (`lib/hecks/adapters/driven/postgres_era.rb` and `postgres_era/`, about 5,000
lines in roughly 60 files). The plain `Postgres` adapter (about 1,500 lines in 15 files) has
no revision support. A domain opts into revisions by binding `postgres_era` instead of
`postgres`.

Two adapters for one database carry two costs: the `postgres_era` key is a second name a
hecksagon must learn, and four files exist in both trees as forks rather than as one class
with a difference in one place:

| File | Plain | Revision | What differs |
|---|---|---|---|
| `events.rb` | 57 | 74 | Mostly naming; the revision version owns the `events` DDL and its index. |
| `sagas.rb` | 72 | 78 | The revision version adds a `domain` column and owns the checkpoint DDL. |
| `dialect.rb` | 93 | 142 | A real storage difference: plain reads one column per attribute; revision reads a shared `state` jsonb blob through a head view. |
| `journal.rb` | 173 | 173 (266 changed lines in diff) | A real semantic difference: the revision write path holds a write lock, appends and projects in one transaction, refuses writes for an unminted shape, and enforces the era fence. |

The fork is not cosmetic. Two of the four files encode the storage layout, and the journal
encodes revision rules in the write path. Those rules cannot live in an era-only directory.

## Decision

There is one `Postgres` adapter. At boot it chooses a **layout** from the domain's hecksagon:

- **Table layout** (the current plain behaviour): one table per aggregate, one column per
  attribute, a `*` select, and the table's own entry log.
- **Revision layout** (the current `PostgresEra` behaviour): a shared `state` jsonb blob per
  aggregate, a head view, field caches, the write lock and era fence, and the mint and
  translation machinery.

The adapter's journal, dialect, events and sagas delegate to the layout for everything that
depends on storage shape. The revision-only directories (`lineage/`, `lineage_manager/` and
their top-level files) load only when the layout is revision. The shared pieces stay shared:
`outbox`, `reconnect`, `shared_connection`.

Rules:

1. **A domain that does not opt into revisions produces the same schema, and behaves the same,
   as `Postgres` does today.** This is the compatibility bar.
2. **The setting is declared in the hecksagon, not in code.** Its name is decided in the 8.0
   change list after the revision rename is settled.
3. **The `postgres_era` adapter key is removed in 8.0.** Whether it first answers with a
   deprecation message is the owner's call; no other alias is kept, as with the chapter
   retirement.

## Alternatives considered

- **Load the revision code as a module into `Postgres`.** Rejected. The fork is in the write
  path and the dialect, not in files a module can add. A module would have to override those
  methods, which is the fork with extra steps.
- **Use the revision layout for everything.** Rejected. It changes the plain adapter's schema
  for every existing `postgres` user. That is a breaking change with no benefit to them.
- **Keep two adapters and share code.** Rejected. It keeps the second name in every hecksagon
  and keeps the forks.

## Consequences

- **Breaking for `postgres_era` users.** Their hecksagons change in 8.0 (adapter key and the
  setting). A migration guide is needed.
- **Schema and data.** Revision tables already exist for revision users. The change must not
  rename or move them. The persisted-name check from the 8.0 list still applies: if a revision
  table name carries the word "era," renaming it is a data migration, not a code change, and
  that decision is separate from this ADR.
- **Test plan.**
  - A plain-domain test that the schema and behaviour are unchanged, run against the table
    layout.
  - The existing `postgres_era` specs, run against the revision layout through `Postgres`.
  - The outbox specs against both layouts.

## Why revisions are Postgres-only

The revision layout depends on Postgres features that the other adapters do not have, and
the guarantees depend on them:

- **Row-level security** makes the journal append-only and fences out writes from superseded
  revisions, enforced by the database (`provisioning.rb` enables and forces RLS on the
  journal).
- **Transaction-scoped advisory locks** serialize ordinal allocation and field-cache updates
  (`head_writes.rb`, `resumable_backfill.rb`).
- **`nextval()` sequences** assign journal ordinals inside that lock.
- **jsonb path queries and views** read the shared state blob.

Other adapters, assessed against those needs:

- **`sqlite`:** feasible, with its single-writer lock standing in for advisory locks. Without
  RLS, the append-only and fence rules move into application code, so anyone holding the file
  can bypass them. A real loss of guarantee.
- **`d1`:** hard. Its transactions are batches, not interactive, so the mint transaction cannot
  hold a lock across its statements. Minting would need redesign.
- **`heki`, `local_storage`, `folder`:** not realistic. They have no transactions or locks, so
  the write lock and fence would have to be built from nothing.
- **`lambda`:** depends on its backing store, so it inherits the answer for that store.

The decision for 8.0 is to keep revisions Postgres-only. `sqlite` is the one to revisit, and
only for a client that accepts an application-level fence in place of RLS.

## Other adapters

The revision layout exists only in `postgres_era`. No other persistence adapter has it, so
this ADR changes nothing for them except where the setting is checked.

| Adapter | Revisions | Outbox |
|---|---|---|
| `postgres` | no (table layout) | yes |
| `postgres_era` | yes (revision layout) | yes |
| `sqlite` | no | yes |
| `memory` | no | yes |
| `heki`, `d1`, `lambda`, `local_storage`, `folder` | no | no |

Rules for them:

1. **A revisions setting on an adapter with no revision layout is refused at boot,** naming the
   adapter and the adapters that support it. It is not ignored. A silent ignore would leave a
   domain believing it has revision history it does not have.
2. **Outbox support is a separate decision, not part of this ADR.** The five adapters with no
   outbox run reactions inline with a boot warning (`warn_undurable_outbox!`). Whether a domain
   with policies or process managers should refuse to boot on them, rather than warn, is an
   owner decision and is listed as an open question below.

## Open questions

- Whether a domain with policies or process managers should refuse to boot on an adapter with
  no outbox (`heki`, `d1`, `lambda`, `local_storage`, `folder`), instead of warning.

- The setting's name and its place in the hecksagon grammar.
- Whether `events` has the same columns in both layouts. The DDL differs (the revision
  version adds an `aggregate` column and an index). Confirm before merging the two DDLs.
- Whether a domain can change layout after it has data. The answer is probably no, and the
  boot should refuse a change rather than migrate.

## Verification status

This ADR is written from `diff` output on the four forked files and from line counts. I have
not run the specs, and I have not read the boot path that picks an adapter. The table and
revision layouts described above are the behaviour the diffs show, not a checked design.
