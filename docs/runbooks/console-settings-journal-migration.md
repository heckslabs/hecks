# Runbook: ConsoleSettings journal migration and split edge (production)

**Status:** Not run. Do not start until the console upgrade to hecks 6 is ready to deploy in the same
window. Read the "Why one window" section first.

**Owner:** the person approving the production write. **Branch:** `adr-0166-translation-split`
(ADR 0166). **Scratch evidence:** the rehearsal verdict `would_mint` over 35 stored rows of 6 aggregates
(split edge `20d28e` to `a1d142`), run against a labelled copy of production's data.

## Why one window

The live console (`platform.embryonaut.ai`, image `console-20261027203026`, on the hecks 4 line) reads
ConsoleSettings through `vendor/embryonaut_console/web/presentation_config.rb` and `web/app.rb`. The
journal `hecks_journal_console_settings` is text-typed and unpartitioned, which is the layout hecks 4 reads.
The migration changes that layout, so the old console cannot read its settings afterwards. The console
upgrade (hecks 6) must deploy in the same window as the migration, or the console stops reading settings.

## What the migration changes

1. Renames the text journal to `hecks_journal_console_settings_text_legacy`, and its leftover
   `hecks_journal_console_settings_era_1` to `..._era_1_text_legacy`.
2. Creates `hecks_journal_console_settings` partitioned by `LIST (era)`, with `era int`, `ordinal bigint`
   from sequence `hecks_journal_console_settings_ordinal`, `state jsonb`, `mirrors jsonb`.
3. Attaches partition `hecks_journal_console_settings_era_1` for `IN (1)`.
4. Copies every row, casting `ordinal::bigint`, `era::int`, `state::jsonb`, `mirrors::jsonb`, and sets the
   sequence to the maximum ordinal.
5. Writes the held era's label: `hecks_eras` row (`domain = 'ConsoleSettings'`, `ordinal = 1`) gets
   `hash = 20d28eea7766b9e25c16d2e7ba22b6c77e94b1807416aa30f2abf9c468da884d` and `label = '20d28e'`.
6. Installs the six `hecks_tr_*` functions from `TransformSql::ALL` if they are missing. The rehearsal
   showed the copy lacked them.

The SQL for steps 1–4 is the transaction run on the scratch copy (`cs_label_scratch`), and it ran cleanly:
237 rows in, 237 out, ordinals 1–237, every value cast.

## Preconditions (stop if any fails)

- [ ] Live journal count equals the dump used for the rehearsal: 237 rows, and the numeric maximum ordinal
      is 237 (`SELECT count(*), max(ordinal::bigint) FROM hecks_journal_console_settings`). Note that
      `max()` on the text column returns 99; use the cast. If rows were added since, re-dump and re-rehearse.
- [ ] `hecks_eras` for `ConsoleSettings` has ordinal 1 with `label IS NULL` in production.
- [ ] Console upgrade image (hecks 6, with the translation edge) built, pushed to ECR, and passing its own
      smoke test against the scratch copy.
- [ ] A fresh RDS snapshot taken and recorded: `aws rds create-db-snapshot` for
      `hecks-platform-rds-database-ymkdjkacmdke`. The 7-day automated restore point (back to
      2026-10-31T15:12:08Z) is the fallback, not the primary backup.
- [ ] A text dump of the journal and of `hecks_eras` taken on the box, copied to a durable location.
- [ ] Maintenance notice: console writes to ConsoleSettings are paused for the window (see Steps).

## Steps

Run all database commands on the platform box through SSM, using the database settings already in the
console's environment. Do not print or copy the secret. Do not run these from a laptop.

1. **Pause writes.** Stop the console container (`docker stop embryonaut-platform-console-1`) so nothing
   writes ConsoleSettings. Record the time. Caddy stays up and returns the site's error page.
2. **Re-check the count** (precondition 1). Stop if it differs from the dump.
3. **Migrate.** Save this as `migrate.sql` on the box and run
   `psql -v ON_ERROR_STOP=1 -1 -f migrate.sql` (one transaction). Keep the output.

   ```sql
   ALTER TABLE hecks_journal_console_settings RENAME TO hecks_journal_console_settings_text_legacy;
   ALTER TABLE hecks_journal_console_settings_era_1 RENAME TO hecks_journal_console_settings_era_1_text_legacy;
   CREATE SEQUENCE IF NOT EXISTS hecks_journal_console_settings_ordinal;
   CREATE TABLE hecks_journal_console_settings (
     ordinal      bigint NOT NULL DEFAULT nextval('hecks_journal_console_settings_ordinal'),
     era          int    NOT NULL,
     aggregate    text   NOT NULL,
     aggregate_id text   NOT NULL,
     operation    text   NOT NULL DEFAULT 'save',
     state        jsonb,
     mirrors      jsonb
   ) PARTITION BY LIST (era);
   CREATE TABLE hecks_journal_console_settings_era_1 (LIKE hecks_journal_console_settings INCLUDING DEFAULTS);
   ALTER TABLE hecks_journal_console_settings ATTACH PARTITION hecks_journal_console_settings_era_1 FOR VALUES IN (1);
   INSERT INTO hecks_journal_console_settings (ordinal, era, aggregate, aggregate_id, operation, state, mirrors)
   SELECT ordinal::bigint, era::int, aggregate, aggregate_id, operation, state::jsonb, mirrors::jsonb
   FROM hecks_journal_console_settings_text_legacy ORDER BY ordinal::bigint;
   SELECT setval('hecks_journal_console_settings_ordinal', (SELECT max(ordinal) FROM hecks_journal_console_settings));
   UPDATE hecks_eras SET hash = '20d28eea7766b9e25c16d2e7ba22b6c77e94b1807416aa30f2abf9c468da884d',
          label = '20d28e'
    WHERE domain = 'ConsoleSettings' AND ordinal::text = '1' AND label IS NULL;
   ```

   The six `hecks_tr_*` functions: if `SELECT count(*) FROM pg_proc WHERE proname LIKE 'hecks_tr_%'`
   returns 0, install them with `TransformSql::ALL` (the owner's provisioning does this on boot).
   The scratch rehearsal confirmed the functions must exist before the mint.
4. **Verify** (all must pass before step 5):
   - `SELECT count(*), count(DISTINCT ordinal) FROM hecks_journal_console_settings` returns 237, 237.
   - `SELECT label FROM hecks_eras WHERE domain = 'ConsoleSettings' AND ordinal::text = '1'` returns `20d28e`.
   - `SELECT count(*) FROM pg_proc WHERE proname LIKE 'hecks_tr_%'` returns 6.
5. **Mint the edge** through hecks. Run `hecks RehearsalRun.request!` against the production copy first and
   confirm `would_mint`. The mint command itself is not yet confirmed for this repo: find it with
   `hecks --help` before running, and do not run the mint by hand.
6. **Deploy the console upgrade** through the service roll: `hecks deploy service_roll.run!` with the new
   tag. Use the deploy path, not a raw `docker` command.
7. **Resume writes:** the service roll starts the container. Check `https://platform.embryonaut.ai/`
   returns 302 to sign-in, then check that a ConsoleSettings collection renders.

## Rollback

- **Before step 6 (console still on the old image):** rename back:
  `ALTER TABLE hecks_journal_console_settings RENAME TO hecks_journal_console_settings_failed;`
  then `ALTER TABLE hecks_journal_console_settings_text_legacy RENAME TO hecks_journal_console_settings;`
  and the same for `_era_1`. Restore the `hecks_eras` label to NULL. Resume writes. The old console reads
  its text journal again.
- **After step 6:** roll the console back to `console-20261027203026` with the service roll, then do the
  rename above. If the journal itself is damaged, restore from the snapshot in the precondition list.
- **Full restore:** RDS point-in-time restore to the time recorded in step 1 is the last resort, and it
  discards every write after that time.

## Not covered by this runbook

- The rust audit (`validate_harness`) did not run in the rehearsal. Run it, or accept the Ruby-only verdict
  in writing.
- The rehearsal does not check head tables, or whether an edge covers every shape change.
- Four rehearsal specs in `spec/hecks_rehearsal_run_spec.rb` fail before and after this work (cross-process
  run outcome). Fix them separately.
