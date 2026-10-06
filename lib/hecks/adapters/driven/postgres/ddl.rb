module Hecks
  module Adapters
    class Postgres
      # The CREATE TABLE statements `SchemaBuilder` runs, as text. `ENTRY_TABLE` takes the
      # quoted table name as `%<table>s`.
      module Ddl
        ENTRY_TABLE = <<~SQL.freeze
          CREATE TABLE IF NOT EXISTS %<table>s (
            sequence     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
            aggregate_id text NOT NULL,
            operation    text NOT NULL DEFAULT 'save',
            state        jsonb NOT NULL,
            mirrors      jsonb
          )
        SQL

        EVENTS = <<~SQL.freeze
          CREATE TABLE IF NOT EXISTS events (
            id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
            name         text NOT NULL,
            aggregate    text NOT NULL,
            aggregate_id text NOT NULL,
            payload      jsonb,
            occurred_at  text
          )
        SQL

        CHECKPOINTS = <<~SQL.freeze
          CREATE TABLE IF NOT EXISTS hecks_checkpoints (
            aggregate_table text PRIMARY KEY,
            last_sequence   bigint NOT NULL DEFAULT 0
          )
        SQL

        SAGA_INSTANCES = <<~SQL.freeze
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
      end
    end
  end
end
