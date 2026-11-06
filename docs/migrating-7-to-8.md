# Migrating from Hecks 7.x to 8.0

**Status: final for the Postgres layout change (ADR 0182).** This page lists what that change
breaks. The other 8.0 breaks listed at the end are not part of this change and are not yet
written up; this page does not promise them. The [CHANGELOG](../CHANGELOG.md) entry for 8.0.0
carries the release wording.
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
the layout is recorded on first boot and a later mismatch is refused.

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
