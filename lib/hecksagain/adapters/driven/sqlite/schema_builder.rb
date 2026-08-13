module Hecksagain
  module Adapters
    class Sqlite
      # The DDL: one table per aggregate head, an append-only entry table
      # beside it, the shared events table, and the two ALTERs that let an
      # older database grow the columns newer code writes.
      module SchemaBuilder
        private

        def create_aggregate_table!
          columns = persisted_fields.map { |field| "#{quote_ident(field[:name])} #{field[:sql_type]}" }
          @db.execute(
            "CREATE TABLE IF NOT EXISTS #{quoted_table} (id TEXT PRIMARY KEY#{columns.empty? ? '' : ', '}#{columns.join(', ')})"
          )
        end

        def create_event_table!
          @db.execute(<<~SQL)
            CREATE TABLE IF NOT EXISTS events (
              id           INTEGER PRIMARY KEY AUTOINCREMENT,
              name         TEXT NOT NULL,
              aggregate    TEXT NOT NULL,
              aggregate_id TEXT NOT NULL,
              payload      TEXT,
              occurred_at  TEXT
            )
          SQL
        end

        def create_entry_table!
          @db.execute(<<~SQL)
            CREATE TABLE IF NOT EXISTS #{quoted_entry_table} (
              sequence     INTEGER PRIMARY KEY AUTOINCREMENT,
              aggregate_id TEXT NOT NULL,
              operation    TEXT NOT NULL DEFAULT 'save',
              state        TEXT NOT NULL,
              mirrors      TEXT
            )
          SQL
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

        # THE OPTIONAL saga-persistence capability's own table (§2/§4) —
        # shared here so `D1`, which `include`s this module verbatim for
        # its own `events`-table DDL (`d1.rb`), gets this for free too.
        # `domain` stays an explicit column even though SQLite has no
        # schema/namespace concept the way Postgres does — matches
        # `hecks_saga_instances`' own Postgres shape (§3) and covers the
        # (uncommon but real) case of a domain explicitly sharing one
        # `database` file/D1 database with another.
        def create_saga_table!
          @db.execute(<<~SQL)
            CREATE TABLE IF NOT EXISTS hecks_saga_instances (
              domain          TEXT NOT NULL,
              process_manager TEXT NOT NULL,
              correlation     TEXT NOT NULL,
              state           TEXT NOT NULL,
              memory          TEXT NOT NULL,
              PRIMARY KEY (domain, process_manager, correlation)
            )
          SQL
        end

        def sql_type(attr)
          return "TEXT" if attr.list?

          SQL_TYPES.fetch(attr.type, "TEXT")
        end
      end
    end
  end
end
