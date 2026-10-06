require "json"

require_relative "sql_query_builder"
require_relative "sqlite/schema_builder"
require_relative "sqlite/codec"
require_relative "sqlite/dialect"
require_relative "sqlite/events"
require_relative "sqlite/repository"
require_relative "sqlite/sagas"
require_relative "sqlite"
require_relative "d1/connection"
require_relative "../../ports/persistence/append_only"
require_relative "../../query_specification/common/null_policy"
require_relative "../../query_specification/common/order_by"
require_relative "../../runtime/errors"
require_relative "../../runtime/event"
require_relative "../../runtime/instance"

module Hecks
  module Adapters
    # Cloudflare D1 (managed SQLite over REST): reuses Sqlite's schema and codec unchanged.
    # Only the transport differs, one HTTP call per query.
    class D1
      include SqlQueryBuilder
      include Sqlite::SchemaBuilder
      include Sqlite::Codec
      include Sqlite::Repository
      include Sqlite::Events
      include Sqlite::Sagas
      include Sqlite::Dialect

      SQL_TYPES = { "Integer" => "INTEGER", "Float" => "REAL" }.freeze

      attr_reader :aggregate

      def persistence_capabilities = [:atomic_put]

      # Creates the aggregate, journal, event and saga tables if absent.
      # Settings: `account_id`, `database_id`, `api_token` (required) and `domain` (saga scope).
      # @raise [Runtime::WiringError] if a required setting is missing or empty
      def initialize(aggregate:, settings: {}, root: nil)
        @aggregate = aggregate
        @db = connect(settings)
        # Saga rows are scoped by domain; one D1 database per domain, so aggregates share it.
        @domain = setting(settings, :domain, aggregate.name).to_s

        # No PRAGMA synchronous: D1 is managed and its query endpoint disallows PRAGMA writes.
        create_aggregate_table!
        create_entry_table!
        ensure_entry_operation_column!
        ensure_entry_mirrors_column!
        create_event_table!
        create_saga_table!
      end

      def table = @aggregate.storage_name

      def append(entry)
        @db.execute(
          "INSERT INTO #{quoted_entry_table} (aggregate_id, operation, state, mirrors) VALUES (?, ?, ?, ?)",
          # Absent mirrors bind SQL NULL, not the JSON text "null" (the column is nullable).
          [entry.id, entry.operation, state_json(entry.state), entry.mirrors && JSON.generate(entry.mirrors)]
        )
        entry
      end

      # The whole journal in append order, for `AppendOnly#recover!` to replay.
      def entries
        @db.execute("SELECT aggregate_id, operation, state, mirrors FROM #{quoted_entry_table} ORDER BY sequence").map do |row|
          state = JSON.parse(row["state"])
          Ports::Persistence::Entry.new(
            operation: row["operation"] || "save",
            id:        row["aggregate_id"],
            state:     Ports::Persistence::StateCodec.decode(@aggregate, state),
            mirrors:   row["mirrors"] && JSON.parse(row["mirrors"])
          )
        end
      end

      # Journals then projects as two HTTP requests; the journal row stays if projecting fails.
      def save(instance)
        entry = Ports::Persistence::Entry.new(operation: "save", id: instance.id.to_s, state: instance.state.dup)
        append(entry)
        project(entry)
      end

      # Stores an entry in one D1 batch; returns `:inserted`, `:replaced` or `:conflicted`.
      #
      # The existence check is the batch's first statement and both writes are gated by
      # WHERE NOT EXISTS, so `insert_only` has no gap between check and write.
      # @return [Symbol] `:conflicted` only when `insert_only` met an existing row
      def atomic_put(entry, insert_only: false)
        results = @db.batch([status_statement(entry, insert_only),
                             entry_statement(entry, insert_only),
                             aggregate_statement(entry, insert_only)])
        results.fetch(0).fetch(0).fetch("status").to_sym
      end

      private

      # The settings are read under a Symbol or a String key; each credential is required.
      def connect(settings)
        credentials = %w[account_id database_id api_token].to_h { |name| [name, setting(settings, name.to_sym, nil)] }
        credentials.each do |name, value|
          raise Runtime::WiringError, "D1 needs a #{name.inspect} in its world settings" if value.to_s.empty?
        end

        Connection.new(account_id: credentials["account_id"], database_id: credentials["database_id"],
                       api_token: credentials["api_token"])
      end

      # A setting read under its Symbol key, then its String key, then `default`.
      def setting(settings, key, default)
        return settings[key] if settings.key?(key)
        return settings[key.to_s] if settings.key?(key.to_s)

        default
      end

      # The batch's first statement: what the put will do, decided against the current row.
      def status_statement(entry, insert_only)
        outcome = insert_only ? "conflicted" : "replaced"
        sql = "SELECT CASE WHEN EXISTS (SELECT 1 FROM #{quoted_table} WHERE id = ?) " \
              "THEN '#{outcome}' ELSE 'inserted' END AS status"
        [sql, [entry.id.to_s]]
      end

      def entry_statement(entry, insert_only)
        # `mirrors` is nullable; see `append`.
        binds = [entry.id, entry.operation, state_json(entry.state), entry.mirrors && JSON.generate(entry.mirrors)]
        head = "INSERT INTO #{quoted_entry_table} (aggregate_id, operation, state, mirrors) "
        return ["#{head}VALUES (?, ?, ?, ?)", binds] unless insert_only

        ["#{head}SELECT ?, ?, ?, ? #{not_exists_sql}", binds + [entry.id.to_s]]
      end

      def aggregate_statement(entry, insert_only)
        instance = Runtime::Instance.new(aggregate: @aggregate, id: entry.id, state: entry.state)
        columns = quoted_columns
        values = instance_values(instance)
        return [upsert_sql(columns), values] unless insert_only

        slots = Array.new(columns.size, "?").join(", ")
        ["INSERT INTO #{quoted_table} (#{columns.join(", ")}) SELECT #{slots} #{not_exists_sql}", values + [entry.id.to_s]]
      end

      def not_exists_sql = "WHERE NOT EXISTS (SELECT 1 FROM #{quoted_table} WHERE id = ?)"

      def dialect_name = "D1"
    end
  end
end
