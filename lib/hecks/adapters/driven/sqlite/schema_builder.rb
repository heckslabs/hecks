require_relative "ddl"

module Hecks
  module Adapters
    class Sqlite
      # DDL for one aggregate: head table, entry table, events, saga and outbox tables.
      module SchemaBuilder
        private

        def create_aggregate_table!
          columns = persisted_fields.map { |field| "#{quote_ident(field[:name])} #{field[:sql_type]}" }
          @db.execute(
            "CREATE TABLE IF NOT EXISTS #{quoted_table} (id TEXT PRIMARY KEY#{", " unless columns.empty?}#{columns.join(", ")})"
          )
          # Called here so D1, which reuses this module, gets automatic indexing too.
          ensure_indexes!
        end

        def create_event_table!
          @db.execute(Ddl::EVENTS)
          # Backs #events_for's per-record lookup (a `corrects` command's history read).
          @db.execute(
            "CREATE INDEX IF NOT EXISTS hecks_events_aggregate_id_idx ON events (aggregate, aggregate_id)"
          )
        end

        def create_entry_table!
          @db.execute(format(Ddl::ENTRY_TABLE, table: quoted_entry_table))
        end

        def ensure_entry_operation_column!
          columns = @db.execute("PRAGMA table_info(#{quoted_entry_table})").map { |row| row["name"] }
          return if columns.include?("operation")

          @db.execute("ALTER TABLE #{quoted_entry_table} ADD COLUMN operation TEXT NOT NULL DEFAULT 'save'")
        end

        def ensure_entry_mirrors_column!
          columns = @db.execute("PRAGMA table_info(#{quoted_entry_table})").map { |row| row["name"] }
          return if columns.include?("mirrors")

          @db.execute("ALTER TABLE #{quoted_entry_table} ADD COLUMN mirrors TEXT")
        end

        # Shared with D1, which includes this module. `domain` is an explicit column so
        # two domains can share one database file.
        def create_saga_table!
          @db.execute(Ddl::SAGA_INSTANCES)
          # The table may predate this column, and SQLite lacks ADD COLUMN IF NOT EXISTS,
          # so a duplicate-column error is treated as already applied.
          @db.execute("ALTER TABLE hecks_saga_instances ADD COLUMN completed_compensations TEXT NOT NULL DEFAULT '[]'")
        rescue StandardError => e
          raise unless e.message.include?("duplicate column name")
        end

        def create_outbox_table!
          @db.execute(Ddl::OUTBOX)
          @db.execute("CREATE INDEX IF NOT EXISTS idx_hecks_outbox_status ON hecks_outbox(aggregate, status)")
        end

        # One row per aggregate table, naming the highest entry `sequence` this table has
        # already had projected into it — shared across every aggregate in the database file,
        # since it is keyed by table name rather than declared per aggregate.
        def create_checkpoint_table!
          @db.execute(Ddl::CHECKPOINTS)
          ensure_checkpoint_compacted_through_column!
        end

        # CREATE TABLE IF NOT EXISTS never adds a column to an existing table, so this healing
        # step matches ensure_entry_operation_column!'s own for the entry table.
        def ensure_checkpoint_compacted_through_column!
          columns = @db.execute("PRAGMA table_info(hecks_checkpoints)").map { |row| row["name"] }
          return if columns.include?("compacted_through")

          @db.execute("ALTER TABLE hecks_checkpoints ADD COLUMN compacted_through INTEGER NOT NULL DEFAULT 0")
        end

        def sql_type(attr)
          return "TEXT" if attr.list?

          SQL_TYPES.fetch(attr.type, "TEXT")
        end

        # Indexes every field a declared query filters or sorts on, entity queries included
        # (they compile against this table too). Idempotent, so it is safe on every boot.
        def ensure_indexes!
          declared_query_fields.each { |field| ensure_index_for_field!(field) }
        end

        def declared_query_fields
          queries = @aggregate.queries + @aggregate.entities.flat_map(&:queries)
          queries.flat_map { |query| query.wheres.map(&:field) + [query.order_by&.field] }
                 .compact.map(&:to_s).uniq
        end

        # A scalar or lifecycle field gets a btree index; a value-object path gets an expression
        # index over `query_expression`'s own text, so the planner matches what queries compile to.
        # List fields are left unindexed: SQLite cannot index json_each elements.
        # Unknown fields are skipped rather than raised, since the DSL already refuses them.
        def ensure_index_for_field!(field)
          name, * = field.to_s.split(".")
          attribute = @aggregate.attribute(name)
          lifecycle_field = @aggregate.lifecycle&.field.to_s == name

          return if !lifecycle_field && attribute.nil?
          return if attribute&.list?

          expression = query_expression(field)
          @db.execute(
            "CREATE INDEX IF NOT EXISTS #{quote_ident(index_name(field))} ON #{quoted_table}(#{expression})"
          )
        end

        # Table-prefixed because SQLite index names are global to the database.
        # The field is sanitized (a dotted path's ".") to stay a valid identifier.
        def index_name(field)
          sanitized = field.to_s.gsub(/[^a-zA-Z0-9_]/, "_")
          "idx_#{table}_#{sanitized}"
        end
      end
    end
  end
end
