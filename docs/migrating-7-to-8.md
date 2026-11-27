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
5. Run `hecks-parse closed --check` over your declaration files and fix what section 6 lists.
6. Run `hecks ModelCheckRun.model_check!` and your own specs.

## 1. Revision names in Ruby and the CLI

"Era" is renamed to "revision" in Ruby constants, CLI verbs and messages. The names stored in
your database do not change, so no data migration is needed.

- **Constants:** `PostgresEra` → `PostgresRevision`; `Era` → `Revision`; `EraBoundary` →
  `RevisionBoundary`; `EraCheck` → `RevisionCheck`; `EraGuard` → `RevisionGuard`;
  `EraIntegrity` → `RevisionIntegrity`; `EraProjectionBackfill` → `RevisionProjectionBackfill`;
  `EraReattest` → `RevisionReattest`; `EraResolution` → `RevisionResolution`; `EraResolver` →
  `RevisionResolver`; `EraStatus` → `RevisionStatus`; `EraStore` → `RevisionStore`;
  `EraTamper` → `RevisionTamper`; `CheckEra` → `CheckRevision`; `ExpectedEra` →
  `ExpectedRevision`; `HeldEra` → `HeldRevision`; `QaEraMint` → `QaRevisionMint`.
- **CLI verbs:** the verbs are generated from the framework bluebook's `Era` aggregate, so the
  prefix changes with it: `hecks era.reattest!` → `hecks revision.reattest!`,
  `era.hold_first!` → `revision.hold_first!`, and every other `era.*` verb, including
  `era.audit_translation`, `era.compaction`, `era.reconcile_plan` and `era.scaffold_translation`.
  Find them with `grep -rn 'era\.' .`.
- **Fixture and file names** such as `expected-era.header` and `hecks_fuzz_postgres_era.world`
  are internal and may stay, but any that a client builds by hand must be listed here.
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
`memory`), or opt in to inline reactions in the hecksagon:

```ruby
inline_reactions true
```

Reactions then run inline with the boot warning, as they do today.

## 6. Declaration files are parsed, not run

The gem no longer runs a `.bluebook`, `.hecksagon`, `.world` or `.contextmap` file as Ruby.
The Rust parser (`hecks-parse`, in `rust/parser`) checks each file against the closed
vocabulary: declaration words with literal arguments, rule expressions in `given`,
`invariant`, `ensures` and `where`, operand arithmetic in `sets`, and the bind and setting verbs
of a hecksagon and a world. The gem builds only from the text the parser admits. A file that
holds anything else is refused before any of it runs, with the file, the line and the reason.

These are refused:

- `require`, `load`, `eval`, `send`, `system`, backticks and any other Ruby method.
- `ENV`, `File`, `Dir` and any other constant at the start of a line or in an argument.
- String interpolation, lambdas, blocks on arguments and `.each` or `.times` loops.
- Method calls inside a rule body, other than the rule words themselves.

What to change:

- **Loops:** write each declaration out. `%w[A B].each { |n| separate_ways n, "C" }` becomes
  one `separate_ways` line per name.
- **Settings read from the environment or a file:** move them behind an adapter, and have the
  world name the adapter.
- **A hecksagon that loaded its own bluebook with `load` or `require`:** write
  `bluebook_from :gem` as the first line of its `Hecks.hecksagon` block.
- **A path built with `File.expand_path` or `__dir__`:** write the path as a literal. A world
  may write `~/` and the adapter expands it.

**The parser binary.** The gem runs `hecks-parse`. Set `HECKS_PARSE_BIN` to a built binary, or
have `cargo` (Rust 1.98.0) on the `PATH`, in which case the gem builds it once into its cache
directory for each version of the parser sources. With neither, loading a declaration file
raises `Hecks::ClosedForm::Parser::Missing`, which names both.

Run `hecks-parse closed --check <files>` to list every file of yours that the parser refuses.

## Not in 8.0

- A `SchemaHistory` aggregate for schema revisions.
- Event translation under eras.
- Renaming the stored `hecks_*era*` names.
