require "digest"

module Hecksagain
  module Adapters
    class PostgresEra
      class Lineage
        # THE READ-SIDE OF THE ERA WORKAROUND. Once a domain mints a
        # second era, `head_view` is a `DISTINCT ON`/`UNION ALL`
        # reduction — and a `where` clause on anything but `id` (its own
        # partition key) cannot be pushed through that reduction, so every
        # declared query pays the cost of reducing the WHOLE aggregate
        # before it can filter anything (see docs/postgres-era-adapter-
        # split-plan.md's own trigger section — this is a real
        # SQL-semantics wall, not a missing index; adding one to
        # `head_view` itself changes nothing, because the planner cannot
        # prove a predicate on a non-partition column commutes with
        # `DISTINCT ON` without risking a stale row winning).
        #
        # THE WORKAROUND: one narrow table per declared `where`-field
        # (never `order_by`-only fields — sorting the reduced output was
        # never blocked by the reduction; only filtering was), holding
        # exactly (id, ordinal, value) — the CURRENT extracted value for
        # every live id, maintained transactionally by `append` alongside
        # the head snapshot it already upserts (same ordinal-guard idiom:
        # `WHERE ordinal < EXCLUDED.ordinal`). A query whose sole `where`
        # is on a cached field never runs the reduction at all: `SELECT id
        # FROM <field>_cache WHERE value <op> $1`, then `SELECT id, state
        # FROM head_view WHERE id = ANY($ids)` — safe THROUGH the
        # reduction because `id` is its own partition key, unlike the
        # original field.
        #
        # SCOPED TO NON-LIST FIELDS ONLY, same reasoning Track A (plain
        # Postgres) and Track B (Sqlite/D1) both landed on independently
        # for their own automatic indexing: this codebase's `contains`
        # compiles to element-membership (`jsonb_array_elements`/
        # `json_each` + `EXISTS`), which a (id, ordinal, value) cache table
        # keyed on ONE scalar value per id has no way to represent — a
        # list field would need one row per (id, element), a different
        # shape this plan does not build. `PostgresEra#eligible_for_cache?`
        # is where that boundary lives.
        module FieldCache
          # Deterministic and collision-free regardless of field-path
          # length or storage-name length — Postgres identifiers cap at 63
          # bytes, and a value-object member path (`compliance.review.
          # deadline_at`) combined with a long storage name could exceed
          # that if built any less defensively. Not meant to be
          # human-readable; `hecks_backfill_progress`/catalog lookups are
          # always driven by this same computed name, never typed by hand.
          def field_cache(storage_name, era, field)
            "hecks_fc_#{Digest::SHA256.hexdigest("#{storage_name}\0#{era}\0#{field}")[0, 20]}"
          end

          # Self-healing, same idiom as `ensure_head_snapshot!`: cheap,
          # unconditional, safe to call on every boot. CREATION is a
          # short-held lock (table doesn't exist yet — nothing to block);
          # BACKFILL runs outside it, chunk by chunk, each chunk its own
          # short lock — never one transaction spanning the scan, per
          # principle 1. `value_expression` is the exact SQL
          # `PostgresEra#query_expression(field)` already compiles for
          # this field, applied against a `state` column this module's own
          # SQL always makes available in scope (see `field_cache_source_sql`)
          # — ONE source of truth for "what does this field mean", not a
          # second hand-rolled copy that could silently drift from what a
          # live query actually filters on.
          def ensure_field_cache!(storage_name, era, field, value_expression)
            name = field_cache(storage_name, era, field)
            unless table_exists?(name)
              nested_transaction("hecks_field_cache_create") do
                @db.exec_params("SELECT pg_advisory_xact_lock(hashtext('hecks_field_cache:' || $1))", [name])
                next if table_exists?(name)

                @db.exec(<<~SQL)
                  CREATE TABLE #{quote(name)} (
                    id      text PRIMARY KEY,
                    ordinal bigint NOT NULL,
                    value   text
                  )
                SQL
                @db.exec("CREATE INDEX IF NOT EXISTS #{quote("#{name}_value_idx")} ON #{quote(name)} (value)")
              end
            end
            backfill_field_cache!(name, storage_name, era, value_expression)
            name
          end

          def backfill_field_cache!(name, storage_name, era, value_expression)
            chunked_backfill!(
              name,
              source_sql: lambda do |cursor|
                <<~SQL
                  SELECT id, ordinal, value FROM (#{field_cache_source_sql(storage_name, era, value_expression)}) reduced
                  #{cursor ? "WHERE id > #{text_literal(cursor)}" : ''}
                  ORDER BY id LIMIT #{ResumableBackfill::CHUNK_SIZE}
                SQL
              end,
              upsert: lambda do |rows|
                upsert_field_cache_rows!(name, rows)
              end
            )
          end

          # THE LIVE-WRITE SIDE — called from `append`, inside the SAME
          # transaction as the journal insert and the head-snapshot
          # upsert, for every field this aggregate has a cache table for.
          # `state_json` is the entry's OWN new state (already the thing
          # `append` is about to write) — bound as a literal jsonb value
          # and aliased `state`, so `value_expression` (built to read a
          # column literally named `state`) evaluates identically here and
          # in every backfill/query-time use, with no separate Ruby-side
          # re-implementation of "how to pick a value-object's member" to
          # keep in sync.
          def upsert_field_cache_row!(name, id, ordinal, state_json, value_expression)
            @db.exec_params(<<~SQL, [id, ordinal, state_json])
              INSERT INTO #{quote(name)} (id, ordinal, value)
              SELECT $1, $2, #{value_expression}
              FROM (SELECT $3::jsonb AS state) src
              ON CONFLICT (id) DO UPDATE SET ordinal = EXCLUDED.ordinal, value = EXCLUDED.value
              WHERE #{quote(name)}.ordinal < EXCLUDED.ordinal
            SQL
          end

          def delete_field_cache_row!(name, id)
            @db.exec_params("DELETE FROM #{quote(name)} WHERE id = $1", [id])
          end

          private

          # The reduced (id, ordinal, state) source a field cache backfills
          # from — NOT the raw journal (unlike `backfill_head_snapshot!`'s
          # own source): a field cache reflects the CURRENT HEAD value,
          # which for era > 1 can come from either this era's own live
          # writes OR an untouched-this-era id whose value still comes
          # from the translated ancestor tail. Era 1 has no ancestor tail
          # (the snapshot table IS the head, verbatim); era N reduces the
          # SAME two sources `compile_head!`'s own final view definition
          # unions (head_compiler.rb) — this is deliberately the identical
          # shape, ordinal kept in the SELECT list instead of dropped,
          # because a backfilled cache row needs a REAL ordinal to guard
          # against a concurrent live write the same way every other
          # upsert in this adapter already does. Ordinals are safe to
          # compare across that union because they come from ONE spanning
          # sequence per domain (see lineage.rb's own header comment) —
          # an ancestor-era ordinal is always numerically smaller than any
          # current-era one, so the ordinary `ordinal <` guard already
          # means the right thing with no era-aware special case.
          def field_cache_source_sql(storage_name, era, value_expression)
            era = era.to_i
            if era == 1
              return "SELECT id, ordinal, #{value_expression} AS value " \
                     "FROM #{quote(head_snapshot(storage_name, era))}"
            end

            held = eras.find { |candidate| candidate[:ordinal] == era }
            view = held && held[:label] && matview(storage_name, era, held[:label])
            ancestor_side =
              if view && view_exists?(view)
                "SELECT ordinal, aggregate_id AS id, state FROM #{quote(view)} WHERE operation = 'save'"
              else
                # No compiled ancestor matview yet (e.g. this era was just
                # minted and compile_head! hasn't run for THIS aggregate) —
                # the live snapshot side alone is the whole truth so far.
                "SELECT NULL::bigint AS ordinal, NULL::text AS id, NULL::jsonb AS state WHERE FALSE"
              end

            <<~SQL
              SELECT id, ordinal, #{value_expression} AS value FROM (
                SELECT DISTINCT ON (id) id, ordinal, state FROM (
                  #{ancestor_side}
                  UNION ALL
                  SELECT ordinal, id, state FROM #{quote(head_snapshot(storage_name, era))}
                ) merged ORDER BY id, ordinal DESC
              ) reduced
            SQL
          end

          def upsert_field_cache_rows!(name, rows)
            rows.each do |row|
              @db.exec_params(
                "INSERT INTO #{quote(name)} (id, ordinal, value) VALUES ($1, $2, $3) " \
                "ON CONFLICT (id) DO UPDATE SET ordinal = EXCLUDED.ordinal, value = EXCLUDED.value " \
                "WHERE #{quote(name)}.ordinal < EXCLUDED.ordinal",
                [row["id"], row["ordinal"], row["value"]]
              )
            end
          end
        end
      end
    end
  end
end
