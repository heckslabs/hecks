# Migrating from Hecks 7.x to 8.0

**Status: draft, covering only the Postgres layout change (ADR 0182) on this branch.** It is not
the 8.0.0 migration guide. The context-map, Composer and reaction items from the earlier 8.0 plan
are not implemented on this branch (`inline_reactions` and the Composer's `saves` key do not exist
in the code), so this page does not describe them. The [CHANGELOG](../CHANGELOG.md) entry is the
release record for this change.
Decisions are recorded in [ADR 0182](decisions/0182-one-postgres-adapter-picks-its-layout-from-the-hecksagon.md).

## Do these first

1. Pin `hecks` 8.0.0 and run `hecks doctor`.
2. Search your hecksagons, scripts, CI jobs, hooks, Makefiles and docs for `postgres_era` and
   `PostgresEra`, and change them as section 1 describes.
3. If a domain binds `postgres_era`, do section 1 before you deploy. Boot refuses it until you do.
4. Run `hecks ModelCheckRun.model_check!` and your own specs.

## 1. The `postgres_era` adapter key

`postgres_era` is removed. The revision layout is the `postgres` adapter with `revisions true`
in the hecksagon:

```ruby
# before
adapter :postgres_era

# after
adapter :postgres
revisions true
```

Boot refuses a binding of `postgres_era` and names this replacement. Stored data is not moved;
nothing records the layout, but the boot checks it: a plain `postgres` binding over a database that
holds the domain's revisions is refused, and a `revisions true` binding over a table-layout database
is refused.

The Ruby class that holds the revision layout is `Hecks::Adapters::PostgresRevision`. If your code
names the old class `PostgresEra`, change it to `PostgresRevision`.

Sweep and benchmark labels change with it: `persistence_parity`, `concurrency` and the bench
target `ruby:postgres_era` now read `postgres_revision` in their capability lists and output.
Settings files that name `right: postgres_era` must change to `right: postgres_revision`.

## Not changed by this release

- **The `Era` family.** `Era`, `EraCheck`, `EraStatus` and the other `Era*` constants, and the
  `era.*` CLI verbs, keep their names. A later release renames them.
- **Stored names.** `hecks_eras`, `hecks_era_texts` and `hecks_current_era` keep their names,
  as do fixture directories such as `persistence_legacy/postgres_era`.
- **Other 8.0 breaks.** Context map spellings, the Composer's `revisions` key, and inline reactions
  on adapters with no outbox belong to other changes and are not covered here.
