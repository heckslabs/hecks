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

## Open questions

- The setting's name and its place in the hecksagon grammar.
- Whether `events` has the same columns in both layouts. The DDL differs (the revision
  version adds an `aggregate` column and an index). Confirm before merging the two DDLs.
- Whether a domain can change layout after it has data. The answer is probably no, and the
  boot should refuse a change rather than migrate.

## Verification status

This ADR is written from `diff` output on the four forked files and from line counts. I have
not run the specs, and I have not read the boot path that picks an adapter. The table and
revision layouts described above are the behaviour the diffs show, not a checked design.
