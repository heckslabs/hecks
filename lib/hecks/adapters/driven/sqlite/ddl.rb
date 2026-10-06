module Hecks
  module Adapters
    class Sqlite
      # The CREATE TABLE statements `SchemaBuilder` runs, as text. `ENTRY_TABLE` takes the
      # quoted table name as `%<table>s`.
      module Ddl
        EVENTS = <<~SQL.freeze
          CREATE TABLE IF NOT EXISTS events (
            id           INTEGER PRIMARY KEY AUTOINCREMENT,
            name         TEXT NOT NULL,
            aggregate    TEXT NOT NULL,
            aggregate_id TEXT NOT NULL,
            payload      TEXT,
            occurred_at  TEXT
          )
        SQL

        ENTRY_TABLE = <<~SQL.freeze
          CREATE TABLE IF NOT EXISTS %<table>s (
            sequence     INTEGER PRIMARY KEY AUTOINCREMENT,
            aggregate_id TEXT NOT NULL,
            operation    TEXT NOT NULL DEFAULT 'save',
            state        TEXT NOT NULL,
            mirrors      TEXT
          )
        SQL

        SAGA_INSTANCES = <<~SQL.freeze
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

        OUTBOX = <<~SQL.freeze
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

        CHECKPOINTS = <<~SQL.freeze
          CREATE TABLE IF NOT EXISTS hecks_checkpoints (
            aggregate_table TEXT PRIMARY KEY,
            last_sequence   INTEGER NOT NULL DEFAULT 0
          )
        SQL
      end
    end
  end
end
