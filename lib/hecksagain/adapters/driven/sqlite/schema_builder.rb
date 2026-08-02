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

        def sql_type(attr)
          return "TEXT" if attr.list?

          SQL_TYPES.fetch(attr.type, "TEXT")
        end
      end
    end
  end
end
