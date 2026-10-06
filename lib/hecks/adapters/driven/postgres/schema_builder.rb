require "digest"

module Hecks
  module Adapters
    class Postgres
      # DDL for the aggregate, entry, event and saga tables, plus the automatic
      # indexes derived from declared queries.
      module SchemaBuilder
        private

        def create_aggregate_table!
          columns = persisted_fields.map { |field| "#{quote_ident(field[:name])} #{field[:sql_type]}" }
          @db.exec(
            "CREATE TABLE IF NOT EXISTS #{quoted_table} (id text PRIMARY KEY#{", " unless columns.empty?}#{columns.join(", ")})"
          )
          # CREATE TABLE IF NOT EXISTS never adds a column to an existing table, so
          # the bookkeeping column is healed on every boot.
          @db.exec("ALTER TABLE #{quoted_table} ADD COLUMN IF NOT EXISTS hecks_version bigint NOT NULL DEFAULT 1")
          # Same healing for declared attributes: existing rows get NULL, as an unset
          # optional attribute would.
          persisted_fields.each do |field|
            @db.exec("ALTER TABLE #{quoted_table} ADD COLUMN IF NOT EXISTS " \
                     "#{quote_ident(field[:name])} #{field[:sql_type]}")
          end
          ensure_indexes!
        end

        def create_entry_table!
          @db.exec(<<~SQL)
            CREATE TABLE IF NOT EXISTS #{quoted_entry_table} (
              sequence     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
              aggregate_id text NOT NULL,
              operation    text NOT NULL DEFAULT 'save',
              state        jsonb NOT NULL,
              mirrors      jsonb
            )
          SQL
        end

        def create_event_table!
          @db.exec(<<~SQL)
            CREATE TABLE IF NOT EXISTS events (
              id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
              name         text NOT NULL,
              aggregate    text NOT NULL,
              aggregate_id text NOT NULL,
              payload      jsonb,
              occurred_at  text
            )
          SQL
          # Backs #events_for's per-record lookup (a `corrects` command's history read).
          @db.exec(
            "CREATE INDEX IF NOT EXISTS hecks_events_aggregate_id_idx ON events (aggregate, aggregate_id)"
          )
        end

        # One row per aggregate table, naming the highest entry `sequence` this table has
        # already had projected into it — shared across every aggregate, since it is keyed
        # by table name rather than declared per aggregate.
        def create_checkpoint_table!
          @db.exec(<<~SQL)
            CREATE TABLE IF NOT EXISTS hecks_checkpoints (
              aggregate_table text PRIMARY KEY,
              last_sequence   bigint NOT NULL DEFAULT 0
            )
          SQL
          # CREATE TABLE IF NOT EXISTS never adds a column to an existing table, so
          # the bookkeeping column is healed on every boot, same as create_aggregate_table!.
          @db.exec("ALTER TABLE hecks_checkpoints ADD COLUMN IF NOT EXISTS compacted_through bigint NOT NULL DEFAULT 0")
        end

        def create_saga_table!
          @db.exec(<<~SQL)
            CREATE TABLE IF NOT EXISTS hecks_saga_instances (
              domain               text NOT NULL,
              process_manager      text NOT NULL,
              correlation          text NOT NULL,
              state                text NOT NULL,
              memory               jsonb NOT NULL,
              completed_compensations  jsonb NOT NULL DEFAULT '[]'::jsonb,
              updated_at           timestamptz NOT NULL DEFAULT now(),
              PRIMARY KEY (domain, process_manager, correlation)
            )
          SQL
          # Heals a table created before this column existed.
          @db.exec("ALTER TABLE hecks_saga_instances ADD COLUMN IF NOT EXISTS completed_compensations jsonb " \
                   "NOT NULL DEFAULT '[]'::jsonb")
        end

        def sql_type(attr)
          return "jsonb" if attr.list? || value_object?(attr)

          SQL_TYPES.fetch(attr.type, "text")
        end

        # Indexes every field a declared query filters or sorts on. Entity queries are
        # skipped: entities have no table, and their queries run in memory.
        def ensure_indexes!
          query_surfaces.each do |owner, queries|
            next unless owner.equal?(@aggregate)

            queries.each { |query| index_query!(query) }
          end
        end

        def query_surfaces
          [[@aggregate, @aggregate.queries]] +
            @aggregate.entities.map { |entity| [entity, entity.queries] }
        end

        def index_query!(query)
          query.wheres.each { |clause| index_field!(clause.field) }
          index_field!(query.order_by.field) if query.order_by
        end

        # A list attribute is never indexed: `contains` compiles to EXISTS over
        # jsonb_array_elements, which neither a btree nor a GIN jsonb index accelerates.
        def index_field!(field)
          # A hop path ("owner/field") has no column or jsonb path to index; it would
          # fail CREATE INDEX with PG::UndefinedColumn.
          return if field.to_s.include?("/")

          name, *_path = field.to_s.split(".")
          attribute = @aggregate.attribute(name)
          return if attribute&.list?

          # Built from the query's own expression so the planner can match it byte for byte.
          expression = query_expression(field.to_s)
          if expression == plain_column(name)
            create_plain_index!(name)
          else
            create_expression_index!(expression, field.to_s)
          end
        end

        def create_plain_index!(column)
          name = index_name(column.to_s)
          @db.exec("CREATE INDEX IF NOT EXISTS #{quote_ident(name)} ON #{quoted_table} (#{quote_ident(column)})")
        end

        def create_expression_index!(expression, field)
          name = index_name(field)
          @db.exec("CREATE INDEX IF NOT EXISTS #{quote_ident(name)} ON #{quoted_table} ((#{expression}))")
        end

        # Hashed so the name stays under Postgres's 63-byte identifier limit and never collides.
        def index_name(field)
          "hecks_idx_#{Digest::SHA256.hexdigest("#{table}:#{field}")[0, 40]}"
        end
      end
    end
  end
end
