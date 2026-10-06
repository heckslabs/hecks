require "digest"

module Hecks
  module Adapters
    class PostgresEra
      class Lineage
        # Per-`where`-field cache tables that let a declared query find ids without reducing
        # the whole aggregate. Holds (id, ordinal, value); lists are not cached
        # (see `eligible_for_cache?`).
        #
        # A `where` on a non-`id` field cannot be pushed through the `DISTINCT ON` reduction in
        # `head_view`, so a query on a cached field reads `<field>_cache` first, then `head_view`
        # by `id` (its partition key).
        module FieldCache
          # Names the cache table for one field of one aggregate in one era.
          #
          # Hashed to stay under Postgres's 63-byte identifier limit; `@domain` is hashed in
          # so two domains sharing a database never share a table (ADR 0059).
          #
          # @param storage_name [String] the aggregate's snake-cased storage name
          # @param era [Integer] ordinal of the era the cache belongs to
          # @param field [String] the cached `where` field, dotted for a value-object member
          # @return [String] unquoted table name, `hecks_fc_` plus 20 hex characters
          def field_cache(storage_name, era, field)
            "hecks_fc_#{Digest::SHA256.hexdigest("#{@domain}\0#{storage_name}\0#{era}\0#{field}")[0, 20]}"
          end

          # Creates one field's cache table if missing, then backfills it from the current head.
          #
          # Safe to call on every boot. Creation holds a short lock; the backfill runs outside it,
          # one chunk per lock, never one transaction over the scan. `value_expression` is the
          # SQL `query_expression(field)` compiles, so cache and live queries agree on the value.
          #
          # @param storage_name [String] the aggregate's snake-cased storage name
          # @param era [Integer] ordinal of the era the cache belongs to
          # @param field [String] the cached `where` field, dotted for a value-object member
          # @param value_expression [String] SQL extracting the value as text from jsonb `state`
          # @return [String] unquoted name of the cache table, as `field_cache` derives it
          # @raise [PG::Error] if Postgres refuses the DDL, a source read, or an upsert
          def ensure_field_cache!(storage_name, era, field, value_expression)
            name = field_cache(storage_name, era, field)
            create_field_cache_table!(name) unless table_exists?(name)
            backfill_field_cache!(name, storage_name, era, value_expression)
            name
          end

          # Fills an existing cache table from the reduced head, one committed chunk at a time,
          # resuming from the cursor in `hecks_backfill_progress`; a no-op once complete.
          #
          # @param name [String] unquoted cache table name, from `field_cache`
          # @param storage_name [String] the aggregate's snake-cased storage name
          # @param era [Integer] ordinal of the era whose head is read
          # @param value_expression [String] SQL extracting the value as text from jsonb `state`
          # @return [void]
          # @raise [PG::Error] if Postgres refuses a source read or an upsert
          def backfill_field_cache!(name, storage_name, era, value_expression)
            chunked_backfill!(
              name,
              source_sql: ->(cursor) { cache_backfill_page_sql(cursor, storage_name, era, value_expression) },
              upsert:     ->(rows) { upsert_field_cache_rows!(name, rows) }
            )
          end

          # Upserts one id's cached value from the state being written, unless the row already
          # carries an equal or newer ordinal.
          #
          # Runs in the journal insert's transaction; `state_json` binds as jsonb `state`.
          #
          # @param name [String] unquoted cache table name, from `field_cache`
          # @param id [String] the aggregate id the entry belongs to
          # @param ordinal [String, Integer] the journal ordinal the entry was written at
          # @param state_json [String] the entry's encoded state, as JSON text
          # @param value_expression [String] SQL extracting the value as text from jsonb `state`
          # @return [void]
          # @raise [PG::Error] if Postgres refuses the upsert
          def upsert_field_cache_row!(name, id, ordinal, state_json, value_expression)
            @db.exec_params(<<~SQL, [id, ordinal, state_json])
              INSERT INTO #{quote(name)} (id, ordinal, value)
              SELECT $1, $2, #{value_expression}
              FROM (SELECT $3::jsonb AS state) src
              ON CONFLICT (id) DO UPDATE SET ordinal = EXCLUDED.ordinal, value = EXCLUDED.value
              WHERE #{quote(name)}.ordinal < EXCLUDED.ordinal
            SQL
          end

          # Removes a deleted id's row so a cached-field query stops offering it. Called from
          # `append` for a delete entry, in the same transaction as the journal insert.
          #
          # @param name [String] unquoted cache table name, from `field_cache`
          # @param id [String] the aggregate id whose row is removed
          # @return [void]
          def delete_field_cache_row!(name, id)
            @db.exec_params("DELETE FROM #{quote(name)} WHERE id = $1", [id])
          end

          private

          # Creates the cache table under a short advisory lock, unless a racing boot made it first.
          def create_field_cache_table!(name)
            nested_transaction("hecks_field_cache_create") do
              @db.exec_params("SELECT pg_advisory_xact_lock(hashtext('hecks_field_cache:' || $1))", [name])
              next if table_exists?(name)

              @db.exec(field_cache_ddl(name))
              @db.exec("CREATE INDEX IF NOT EXISTS #{quote("#{name}_value_idx")} ON #{quote(name)} (value)")
            end
          end

          def field_cache_ddl(name)
            <<~SQL
              CREATE TABLE #{quote(name)} (
                id      text PRIMARY KEY,
                ordinal bigint NOT NULL,
                value   text
              )
            SQL
          end

          # One chunk of the reduced head, after `cursor` when the backfill resumes.
          def cache_backfill_page_sql(cursor, storage_name, era, value_expression)
            <<~SQL
              SELECT id, ordinal, value FROM (#{field_cache_source_sql(storage_name, era, value_expression)}) reduced
              #{"WHERE id > #{text_literal(cursor)}" if cursor}
              ORDER BY id LIMIT #{ResumableBackfill::CHUNK_SIZE}
            SQL
          end

          # The reduced (id, ordinal, state) source a cache backfills from. Unlike the head
          # snapshot's source it reduces the ancestor tail too (era N > 1 mirrors `compile_head!`)
          # with ordinal kept; ordinals share one sequence per domain, so `ordinal <` holds.
          def field_cache_source_sql(storage_name, era, value_expression)
            era = era.to_i
            return era_one_cache_source_sql(storage_name, era, value_expression) if era == 1

            merged_cache_source_sql(storage_name, era, value_expression)
          end

          def era_one_cache_source_sql(storage_name, era, value_expression)
            "SELECT id, ordinal, #{value_expression} AS value " \
              "FROM #{quote(head_snapshot(storage_name, era))}"
          end

          def merged_cache_source_sql(storage_name, era, value_expression)
            <<~SQL
              SELECT id, ordinal, #{value_expression} AS value FROM (
                SELECT DISTINCT ON (id) id, ordinal, state FROM (
                  #{ancestor_side_sql(storage_name, era)}
                  UNION ALL
                  SELECT ordinal, id, state FROM #{quote(head_snapshot(storage_name, era))}
                ) merged ORDER BY id, ordinal DESC
              ) reduced
            SQL
          end

          # The ancestor era's saved rows from its compiled matview, or an empty relation.
          def ancestor_side_sql(storage_name, era)
            held = eras.find { |candidate| candidate[:ordinal] == era }
            view = held && held[:label] && matview(storage_name, era, held[:label])
            if view && view_exists?(view)
              return "SELECT ordinal, aggregate_id AS id, state FROM #{quote(view)} WHERE operation = 'save'"
            end

            # No compiled ancestor matview yet (era just minted): snapshot side only.
            "SELECT NULL::bigint AS ordinal, NULL::text AS id, NULL::jsonb AS state WHERE FALSE"
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
