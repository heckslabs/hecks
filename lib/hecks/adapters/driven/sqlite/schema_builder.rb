require_relative "index_builder"

module Hecks
  module Adapters
    class Sqlite
      # The DDL: one table per aggregate head, an append-only entry table
      # beside it, the shared events table, and the two ALTERs that let an
      # older database grow the columns newer code writes. The automatic
      # indexing that follows table creation lives in the sibling
      # `IndexBuilder` module (split out only to keep this one under its
      # line budget).
      module SchemaBuilder
        include IndexBuilder

        SAGA_TABLE_SQL = <<~SQL.freeze
          CREATE TABLE IF NOT EXISTS hecks_saga_instances (
            domain               TEXT NOT NULL,
            process_manager      TEXT NOT NULL,
            correlation          TEXT NOT NULL,
            state                TEXT NOT NULL,
            memory               TEXT NOT NULL,
            completed_compensations  TEXT NOT NULL DEFAULT '[]',
            PRIMARY KEY (domain, process_manager, correlation)
          )
        SQL

        OUTBOX_TABLE_SQL = <<~SQL.freeze
          CREATE TABLE IF NOT EXISTS hecks_outbox (
            id           INTEGER PRIMARY KEY AUTOINCREMENT,
            delivery_id  TEXT NOT NULL UNIQUE,
            event_uid    TEXT NOT NULL,
            aggregate    TEXT NOT NULL,
            domain       TEXT NOT NULL,
            kind         TEXT NOT NULL,
            consumer     TEXT NOT NULL,
            event        TEXT NOT NULL,
            status       TEXT NOT NULL DEFAULT 'pending',
            attempts     INTEGER NOT NULL DEFAULT 0,
            error        TEXT,
            enqueued_at  TEXT NOT NULL,
            claimed_at   TEXT,
            settled_at   TEXT
          )
        SQL

        private

        def create_aggregate_table!
          columns = persisted_fields.map { |field| "#{quote_ident(field[:name])} #{field[:sql_type]}" }
          @db.execute(
            "CREATE TABLE IF NOT EXISTS #{quoted_table} (id TEXT PRIMARY KEY#{', ' unless columns.empty?}#{columns.join(', ')})"
          )
          # Right here, not as a separate step in `Sqlite#initialize` —
          # `create_aggregate_table!` is the one piece of DDL `D1`
          # already calls verbatim through this same shared module
          # (`d1.rb`'s own header: "reuses Sqlite::SchemaBuilder and
          # Sqlite::Codec unchanged"). Folding index creation in here,
          # right after the table it indexes exists, is what makes D1's
          # own automatic indexing a real, running thing rather than an
          # aspiration that only Sqlite ever calls — no D1-specific
          # wiring needed, because D1 never has to know this exists.
          ensure_indexes!
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

        # The optional saga-persistence capability's own table (§2/§4) —
        # shared here so `D1`, which `include`s this module verbatim for
        # its own `events`-table DDL (`d1.rb`), gets this for free too.
        # `domain` stays an explicit column even though SQLite has no
        # schema/namespace concept the way Postgres does — matches
        # `hecks_saga_instances`' own Postgres shape (§3) and covers the
        # (uncommon but real) case of a domain explicitly sharing one
        # `database` file/D1 database with another.
        def create_saga_table!
          @db.execute(SAGA_TABLE_SQL)
          add_saga_completed_compensations_column!
        end

        # `CREATE TABLE IF NOT EXISTS` above is a no-op against a table
        # this same domain already created before this column existed
        # — the same reason Postgres's own `create_saga_table!` needs
        # its own `ADD COLUMN IF NOT EXISTS`. SQLite/D1's own `ALTER
        # TABLE ... ADD COLUMN` has no `IF NOT EXISTS` guard on every
        # version this adapter supports, so a duplicate-column error
        # is caught and treated as "already there" rather than relied
        # on to never happen.
        def add_saga_completed_compensations_column!
          @db.execute("ALTER TABLE hecks_saga_instances ADD COLUMN completed_compensations TEXT NOT NULL DEFAULT '[]'")
        rescue StandardError => e
          raise unless e.message.include?("duplicate column name")
        end

        def create_outbox_table!
          @db.execute(OUTBOX_TABLE_SQL)
          @db.execute("CREATE INDEX IF NOT EXISTS idx_hecks_outbox_status ON hecks_outbox(aggregate, status)")
        end

        def sql_type(attr)
          return "TEXT" if attr.list?

          SQL_TYPES.fetch(attr.type, "TEXT")
        end
      end
    end
  end
end
