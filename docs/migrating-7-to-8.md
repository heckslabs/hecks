# Migrating from Hecks 7.x to 8.0

**Status: draft.** This page lists the breaks planned for 8.0.0 and is not final until the
release is cut. The [CHANGELOG](../CHANGELOG.md) entry for 8.0.0 will carry the full wording.
Decisions are recorded in [ADR 0182](decisions/0182-one-postgres-adapter-picks-its-layout-from-the-hecksagon.md).

## Do these first

1. Pin `hecks` 8.0.0 and run `hecks doctor`.
2. Search your hecksagons, scripts, CI jobs, hooks, Makefiles and docs for the names in
   sections 1 to 4 and change them.
3. If a domain binds `postgres_era`, do section 2 before you deploy. Boot refuses it until you do.
4. If a domain has policies or process managers and binds an adapter with no outbox, do section 5
   before you deploy. Boot refuses it until you do.
5. Run `hecks ModelCheckRun.model_check!` and your own specs.

## 1. Revision names in Ruby and the CLI

"Era" is renamed to "revision" in Ruby constants, CLI verbs and messages. The names stored in
your database do not change, so no data migration is needed.

- **Constants:** `PostgresEra` → `PostgresRevision` (adapter class), `EraGuard` → `RevisionGuard`,
  `EraCheck` → `RevisionCheck`, `EraResolution` → `RevisionResolution`, `EraStatus` →
  `RevisionStatus`, `HeldEra` → `HeldRevision`, and the rest of the `Era*` family.
- **CLI verbs:** `era.audit_translation` → `revision.audit_translation`, `era.reconcile` →
  `revision.reconcile`, `era.reattest` → `revision.reattest`, and the rest of the `era.*` verbs.
  Find them with `grep -rn 'era\.' .`.
- **Stored names are unchanged:** `hecks_eras`, `hecks_era_texts` and `hecks_current_era` keep
  their names.

## 2. The `postgres_era` adapter key

`postgres_era` is removed. Use `postgres` and turn revisions on in the hecksagon:

```ruby
# before
adapter :postgres_era

# after
adapter :postgres
revisions true
```

Boot refuses a binding of `postgres_era` and names this replacement. Stored data is not moved;
the layout is recorded on first boot and a later mismatch is refused.

## 3. Context map spellings

- `as: :anticorruption_layer` → `as: :anti_corruption_layer`
- `acknowledges:` → `accepted_findings:` on `relate`

## 4. Composer timeline key

The Composer's save-history key `revisions` is renamed to `saves`. Anything that reads the
Composer's timeline JSON must change the key.

## 5. Reactions on an adapter with no outbox

A domain with policies or process managers no longer boots on `heki`, `d1`, `lambda`,
`local_storage` or `folder`. Either bind an adapter with an outbox (`postgres`, `sqlite` or
`memory`), or opt in to inline reactions in the hecksagon. The opt-in's name is not decided yet
and will be filled in here before release.

## Not in 8.0

- A `SchemaHistory` aggregate for schema revisions.
- Event translation under eras.
- Renaming the stored `hecks_*era*` names.
