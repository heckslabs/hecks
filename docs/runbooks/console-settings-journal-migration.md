# Runbook: ConsoleSettings journal migration and split edge (production)

**Status:** Not run. Do not start until the console upgrade to hecks 6 is ready to deploy in the same
window. Read the "Why one window" section first.

**Owner:** the person approving the production write. **Branch:** `adr-0166-translation-split`
(ADR 0166). **Scratch evidence:** the rehearsal verdict `would_mint` over 35 stored rows of 6 aggregates
(split edge `20d28e` to `a1d142`), run against a labelled copy of production's data.

## Why one window

The live console (`platform.embryonaut.ai`, image `console-20261027203026`, hecks 4.0.0) reads
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

- [ ] Live journal count equals the count in the dump used for the rehearsal (237), and max ordinal is 99
      or higher exactly as dumped. If rows were added since, re-dump and re-rehearse first.
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

1. **Pause writes.** Put the console into read-only mode for ConsoleSettings, or stop the console
   container. Record the time. Confirm no writes by comparing the journal count before and after.
2. **Re-check the count.** Stop if it differs from the dump.
3. **Migrate.** Run the transaction from `docs/runbooks/...` section "What the migration changes" as one
   `psql` script with `ON_ERROR_STOP=1`. Keep the output.
4. **Label the era** (step 5 above), in the same transaction.
5. **Verify** (all must pass before continuing):
   - `SELECT count(*), count(DISTINCT ordinal) FROM hecks_journal_console_settings` returns 237, 237.
   - `SELECT label FROM hecks_eras WHERE domain='ConsoleSettings' AND ordinal=1` returns `20d28e`.
   - The six `hecks_tr_*` functions exist.
6. **Mint the edge** through hecks, not by hand:
   `hecks RehearsalRun.request!` is the rehearsal and must return `would_mint` first. Then the mint runs
   from the deploy path for the console upgrade (ADR 0166 branch, `journal_store/edge_audit.rb`
   and `coverage_check.rb` in the mint's audit). Record the era created.
7. **Deploy the console upgrade** through the service roll: `hecks deploy service_roll.run!` with the
   new tag, not a raw `docker` command. Confirm the container reports `shape 2`.
8. **Resume writes** and check the site: `https://platform.embryonaut.ai/` returns 302 to sign-in, and
   the presentation config loads (collections render).

## Rollback

- **Before step 7 (console still on the old image):** rename back:
  `ALTER TABLE hecks_journal_console_settings RENAME TO hecks_journal_console_settings_failed;`
  then `ALTER TABLE hecks_journal_console_settings_text_legacy RENAME TO hecks_journal_console_settings;`
  and the same for `_era_1`. Restore the `hecks_eras` label to NULL. Resume writes. The old console reads
  its text journal again.
- **After step 7:** roll the console back to `console-20261027203026` with the service roll, then do the
  rename above. If the journal itself is damaged, restore from the snapshot in the precondition list.
- **Full restore:** RDS point-in-time restore to the time recorded in step 1 is the last resort, and it
  discards every write after that time.

## Not covered by this runbook

- The rust audit (`validate_harness`) did not run in the rehearsal. Run it, or accept the Ruby-only verdict
  in writing.
- The rehearsal does not check head tables, or whether an edge covers every shape change.
- Four rehearsal specs in `spec/hecks_rehearsal_run_spec.rb` fail before and after this work (cross-process
  run outcome). Fix them separately.
