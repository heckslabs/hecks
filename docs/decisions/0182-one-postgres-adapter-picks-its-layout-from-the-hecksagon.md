# One Postgres adapter picks its layout from the hecksagon

**Status:** Accepted. Built for Hecks 8.0, on main ahead of the 8.0 release. Date: 2026-11-04; built 2026-11-27. The open questions were decided by the owner on 2026-11-04. What was built, and the one part of the decision left for later, is under "As built" at the end.

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
2. **The setting is declared in the hecksagon, not in code.** Its name is `revisions true`
   (see the open questions).
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
- **Schema and data.** Revision tables already exist for revision users, and this ADR does not
  move them. Stored names keep the word "era": `hecks_eras`, `hecks_era_texts` and
  `hecks_current_era` (the last not confirmed as a table, view or column). Renaming a stored
  name is a data migration, not a code change, so 8.0 renames only Ruby constants, CLI verbs
  and messages. Stored names are renamed later, in a release of their own.
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

Decided by the owner on 2026-11-04, each as recommended.

1. **Refuse or warn on no outbox. Decided: refuse.** Refuse to boot when a domain declares policies or
   process managers on `heki`, `d1`, `lambda`, `local_storage` or `folder`, unless the
   hecksagon explicitly opts into inline reactions. Breaking, so it belongs in 8.0.
2. **Setting name and grammar. Decided: `revisions true` in the hecksagon.** This works only if
   the Composer's `revisions` key is renamed to `saves` in the 8.0 list.
3. **Changing layout after data exists. Decided: refuse at boot.** Record the layout in a
   metadata table on first boot and compare on every later boot. A migration tool can come
   later, outside 8.0.
4. **Removal of `postgres_era`. Decided: fail at boot with a message naming the replacement
   (`postgres` plus `revisions true`). A loud, specific error is cheaper to diagnose than a
   silent removal.**

## Verification status

The table and revision DDL for `events` and `sagas` was read and matches. The `dialect.rb` and
`journal.rb` differences come from reading the diffs and the code paths they touch. The boot path
that selects an adapter was read and changed (see "As built"), and the specs listed there were run
against a Postgres 16 server. `hecks_current_era` is a row-level-security policy on the journal
(`CREATE POLICY hecks_current_era`, in the Ruby mint transaction and the Rust host's mint), not a
table, view or column. Lambda's backing store was not checked.

## As built

**One adapter name, two layouts.** `persisted_by "Postgres"` is the only Postgres binding.
`Ports::Persistence::Layout.adapter_class` asks the bound adapter's class for `layout_class`, and
`Adapters::Postgres.layout_class(revisions:)` answers itself (the table layout) or the revision
layout's class. `revisions?` is true when the domain's own hecksagon says `revisions true`, or when
a hecksagon that says it attaches the domain and hands it its root `persisted_by` default. Every
caller that turned a bind into a class goes through it: the repository factory, the boot's adapter
load (which registers the era plugin), the era gate and status, the tenant check, the kept-ledger
read, the lineage export and the era tools. The world's settings stay under `persisted_by("Postgres")`.
A revision-only setting (`formerly`, `allow_superuser`, `mint_eras`, `disposable_ledger`,
`mints_era`) given to a domain on the table layout is refused, naming `revisions true`.

**The revision layout keeps its implementation.** The revision layout's class is still
`Hecks::Adapters::PostgresEra` with its `postgres_era/` tree, reached only as Postgres's layout.
The delegation this decision describes (one adapter whose journal, dialect, events and sagas
delegate to the layout, with the forked `events.rb` and `sagas.rb` merged) was not done for 8.0. It
changes no hecksagon, world or stored name, so it can land in a minor release.

**The layout record (open question 3).** `hecks_layouts` holds one row per domain
(`domain` primary key, `layout` of `table` or `revisions`, `recorded_at`). The table layout records
itself on its first boot. The revision layout records itself when the domain is first provisioned
(`Lineage#ensure_base!` in Ruby, `mint::ensure_base` in the Rust host), and its boot only reads.
Every boot compares: the recorded row, else the database's own evidence (held eras for the domain
mean the revision layout, an aggregate's `<storage>_entries` log the table layout). A boot whose
hecksagon chose the other layout is refused, in the same words on both runtimes:

```
cannot boot <Domain> in Postgres's <layout> layout: its database holds <Domain> in the <held>
layout, and a layout cannot change once data exists. To keep the data, <remove|keep> `revisions
true` <from|in> its hecksagon; to start over, point the world at a database that holds no <Domain>.
```

`schema_revision.rename_domain` moves the row with the rest of the domain's history.

**The removal (open question 4 and rule 3).** `postgres_era.adapter` is deleted. A hecksagon bind,
a world `default_adapter` or a world `persisted_by` block naming `PostgresEra` (any case, with or
without underscores) fails the boot before any adapter loads, and `AdapterNamespace.resolve`
refuses the name too, so no lookup by name reaches the class:

```
<Domain>: its hecksagon binds PostgresEra, which Hecks 8.0 removed. Write persisted_by "Postgres"
plus `revisions true` in the hecksagon (ADR 0182) instead: PostgresEra is now Postgres's revision
layout, chosen in the hecksagon.
```

The Rust host refuses an IR that binds it with the same words (`refuse_retired_adapters`), and
serves `Postgres` and `Memory` only. The Rust build's lineage and kept passes read
`revisions true` from the hecksagon instead of scanning adapter classes for `lineage_capable?`.

**Other adapters (rule 1).** `revisions true` is refused unless at least one of the domain's
aggregates resolves to `Postgres`; a domain may keep some aggregates in Memory beside them.

**Test plan, as run.**

- Table layout unchanged: `spec/adapters/driven/postgres_table_layout_spec.rb` (the same tables
  and columns as before, plus `hecks_layouts`).
- Revision layout through `Postgres`: `spec/adapters/driven/postgres_revisions_boot_spec.rb`, and
  the `postgres_era` specs, which build the layout's class directly or boot `persisted_by
  "Postgres"` with `revisions true`.
- Outbox against both layouts: `spec/runtime/outbox_postgres_spec.rb`.
- The record: `spec/adapters/driven/postgres_layout_record_spec.rb` and the `layout` and
  `boot_check` tests in `rust/host/src/store/mint.rs`.
- The removal: `spec/runtime/retired_postgres_era_spec.rb`, `rust/host/core/src/ir.rs` and
  `rust/host/src/boundary_fuzz/ir.rs`.
