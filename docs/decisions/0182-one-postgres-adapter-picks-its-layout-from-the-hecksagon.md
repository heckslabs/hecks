# One Postgres adapter picks its layout from the hecksagon

**Status:** Proposed. Date: 2026-11-04. Owner: to be decided. Not yet built.

## Context

Revision support (era support, to be renamed in the 8.0 change list) lives in a second
adapter, `PostgresEra` (`lib/hecks/adapters/driven/postgres_era.rb` and `postgres_era/`, about
5,000 lines in roughly 60 files). The plain `Postgres` adapter (about 1,500 lines in 15 files)
has no revision support. A domain opts into revisions by binding `postgres_era` instead of
`postgres`.

Two adapters for one database carry two costs: the `postgres_era` key is a second name a
hecksagon must learn, and four files exist in both trees as forks rather than as one class
with a difference in one place:

| File | Plain | Revision | What differs |
|---|---|---|---|
| `events.rb` | 57 | 74 | Naming and where the DDL runs. Same table and index in both; plain creates them in `ddl.rb` and `schema_builder.rb`. |
| `sagas.rb` | 72 | 78 | Naming and where the DDL runs. Same table, columns and key in both. |
| `dialect.rb` | 93 | 142 | A real storage difference: plain reads one column per attribute; revision reads a shared `state` jsonb blob through a head view. |
| `journal.rb` | 173 | 173 (266 changed lines in diff) | A real semantic difference: the revision write path holds a write lock, appends and projects in one transaction, refuses writes for an unminted shape, and enforces the era fence. |

The fork is not cosmetic in two files. `dialect.rb` and `journal.rb` encode the storage layout
and the revision rules in the write path, and those rules cannot live in an era-only
directory. `events.rb` and `sagas.rb` differ only in naming over identical DDL.

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
   as `Postgres` does today.** This is the compatibility bar. The `events` and `sagas` tables
   already match, so the bar holds for them without change.
2. **The setting is declared in the hecksagon, not in code.** Its name is decided in the 8.0
   change list after the revision rename is settled.
3. **The `postgres_era` adapter key is removed in 8.0.** No alias is kept, as with the chapter
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
- **`lambda`:** not assessed. Its answer would follow its backing store, which I have not
  checked.

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
   with policies or process managers should refuse to boot on them is listed as an open
   question below.

## Open questions

Each has a proposed resolution. None is decided.

1. **Refuse or warn on no outbox.** Proposed: refuse to boot when a domain declares policies or
   process managers on `heki`, `d1`, `lambda`, `local_storage` or `folder`, unless the
   hecksagon explicitly opts into inline reactions. Breaking, so it belongs in 8.0.
2. **Setting name and grammar.** Proposed: `revisions true` in the hecksagon. This works only if
   the Composer's `revisions` key is renamed to `saves` in the 8.0 list.
3. **Changing layout after data exists.** Proposed: refuse at boot. Record the layout in a
   metadata table on first boot and compare on every later boot. A migration tool can come
   later, outside 8.0.
4. **Removal of `postgres_era`.** Proposed: fail at boot with a message naming the replacement
   (`postgres` plus `revisions true`). A loud, specific error is cheaper to diagnose than a
   silent removal.

## Verification status

The table and revision DDL for `events` and `sagas` was read and matches. The `dialect.rb` and
`journal.rb` differences come from reading the diffs and the code paths they touch. The specs
were not run, and the boot path that selects an adapter was not read. Lambda's backing store
was not checked.
