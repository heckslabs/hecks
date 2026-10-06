require "json"
require "net/http"
require "uri"

require_relative "sql_query_builder"
require_relative "sqlite/schema_builder"
require_relative "sqlite/codec"
require_relative "sqlite"
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
      # HTTP transport exposing the slice of `SQLite3::Database` the shared SQLite code uses.
      class Connection
        ENDPOINT = "https://api.cloudflare.com/client/v4".freeze

        def initialize(account_id:, database_id:, api_token:)
          @uri = URI("#{ENDPOINT}/accounts/#{account_id}/d1/database/#{database_id}/query")
          @api_token = api_token
        end

        def execute(sql, binds = [])
          response_results({ sql: sql, params: binds }).first.fetch("results", [])
        end

        # D1 batches are transactions: statements run in order and a failure rolls all back.
        def batch(statements)
          payload = {
            batch: statements.map do |sql, binds|
              { sql: sql, params: binds || [] }
            end
          }
          response_results(payload).map { |result| result.fetch("results", []) }
        end

        private

        def response_results(payload)
          request = Net::HTTP::Post.new(@uri)
          request["Authorization"] = "Bearer #{@api_token}"
          request["Content-Type"] = "application/json"
          request.body = JSON.generate(payload)

          response = Net::HTTP.start(@uri.host, @uri.port, use_ssl: true) { |http| http.request(request) }
          body = parse_d1_body(response)
          messages = (body["errors"] || []).map { |error| error["message"] }.join("; ")

          raise Runtime::WiringError, "D1 query failed: #{messages.empty? ? response.body : messages}" unless body["success"]

          results = body.fetch("result")
          failed = results.find { |result| result["success"] == false }
          raise Runtime::WiringError, "D1 query failed: #{failed_statement_detail(failed, messages)}" if failed

          results
        end

        def parse_d1_body(response)
          JSON.parse(response.body)
        rescue JSON::ParserError
          raise Runtime::WiringError, "D1 query failed: non-JSON response (HTTP #{response.code}): #{response.body}"
        end

        # Prefers the statement's own error/message (by key presence) over the whole-response one.
        def failed_statement_detail(failed, messages)
          detail =
            if failed.key?("error")
              failed["error"]
            elsif failed.key?("message")
              failed["message"]
            else
              messages
            end
          detail.to_s.empty? ? "a batched statement failed" : detail
        end

        public

        def get_first_row(sql, binds = [])
          execute(sql, binds).first
        end

        def get_first_value(sql, binds = [])
          get_first_row(sql, binds)&.values&.first
        end
      end

      include SqlQueryBuilder
      include Sqlite::SchemaBuilder
      include Sqlite::Codec

      SQL_TYPES = { "Integer" => "INTEGER", "Float" => "REAL" }.freeze

      attr_reader :aggregate

      def persistence_capabilities = [:atomic_put]

      # Creates the aggregate, journal, event and saga tables if absent.
      # Settings: `account_id`, `database_id`, `api_token` (required) and `domain` (saga scope).
      # @raise [Runtime::WiringError] if a required setting is missing or empty
      def initialize(aggregate:, settings: {}, root: nil)
        @aggregate = aggregate

        account_id  = settings.key?(:account_id)  ? settings[:account_id]  : settings["account_id"]
        database_id = settings.key?(:database_id) ? settings[:database_id] : settings["database_id"]
        api_token   = settings.key?(:api_token)   ? settings[:api_token]   : settings["api_token"]
        { "account_id" => account_id, "database_id" => database_id, "api_token" => api_token }.each do |name, value|
          raise Runtime::WiringError, "D1 needs a #{name.inspect} in its world settings" if value.to_s.empty?
        end

        @db = Connection.new(account_id: account_id, database_id: database_id, api_token: api_token)
        # Saga rows are scoped by domain; one D1 database per domain, so aggregates share it.
        @domain = (
          if settings.key?(:domain)
            settings[:domain]
          elsif settings.key?("domain")
            settings["domain"]
          else
            aggregate.name
          end
        ).to_s

        # No PRAGMA synchronous: D1 is managed and its query endpoint disallows PRAGMA writes.
        create_aggregate_table!
        create_entry_table!
        ensure_entry_operation_column!
        ensure_entry_mirrors_column!
        create_event_table!
        create_saga_table!
      end

      def table = @aggregate.storage_name

      def find(id)
        row = @db.get_first_row("SELECT * FROM #{quoted_table} WHERE id = ?", [id.to_s])
        return nil unless row

        Runtime::Instance.new(aggregate: @aggregate, id: row["id"], state: decode(row))
      end

      # Lists every record, ordered by id or by `order_by` when it names an attribute.
      # @raise [Runtime::WiringError] if `order_by` names no attribute of the aggregate
      def all(order_by: nil, direction: :asc)
        order_sql = "ORDER BY id"
        if order_by
          name = order_by.to_s.split(".").first
          unless @aggregate.lifecycle&.field.to_s == name || @aggregate.attribute(name)
            raise Runtime::WiringError,
                  "#{@aggregate.name} has no attribute #{order_by.inspect} to order by"
          end

          spec = QuerySpecification::Common::OrderBy.new(field: order_by, direction: direction)
          order_sql = "ORDER BY #{order_clause(spec, nil)}"
        end

        @db.execute("SELECT * FROM #{quoted_table} #{order_sql}").map do |row|
          Runtime::Instance.new(aggregate: @aggregate, id: row["id"], state: decode(row))
        end
      end

      def count = @db.get_first_value("SELECT COUNT(*) FROM #{quoted_table}").to_i

      def append(entry)
        @db.execute(
          "INSERT INTO #{quoted_entry_table} (aggregate_id, operation, state, mirrors) VALUES (?, ?, ?, ?)",
          # Absent mirrors bind SQL NULL, not the JSON text "null" (the column is nullable).
          [entry.id, entry.operation, state_json(entry.state), entry.mirrors && JSON.generate(entry.mirrors)]
        )
        entry
      end

      def project(entry)
        return @db.execute("DELETE FROM #{quoted_table} WHERE id = ?", [entry.id]) if entry.delete?

        instance = Runtime::Instance.new(aggregate: @aggregate, id: entry.id, state: entry.state)
        columns = (["id"] + persisted_fields.map { |field| field[:name].to_s }).map { |c| quote_ident(c) }
        values  = [instance.id.to_s] + persisted_fields.map { |field| encode_field(field, instance[field[:name]]) }
        slots   = Array.new(columns.size, "?").join(", ")

        @db.execute(
          "INSERT OR REPLACE INTO #{quoted_table} (#{columns.join(", ")}) VALUES (#{slots})",
          values
        )
        instance
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

      # Clears the aggregate table and its journal; events and saga rows stay.
      def reset!
        @db.execute("DELETE FROM #{quoted_table}")
        @db.execute("DELETE FROM #{quoted_entry_table}")
        self
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
      # rubocop:disable-next Metrics/AbcSize
      # rubocop:disable-next Metrics/MethodLength
      def atomic_put(entry, insert_only: false)
        instance = Runtime::Instance.new(aggregate: @aggregate, id: entry.id, state: entry.state)
        columns = (["id"] + persisted_fields.map { |field| field[:name].to_s }).map { |column| quote_ident(column) }
        values = [instance.id.to_s] + persisted_fields.map { |field| encode_field(field, instance[field[:name]]) }
        slots = Array.new(columns.size, "?").join(", ")
        not_exists = "WHERE NOT EXISTS (SELECT 1 FROM #{quoted_table} WHERE id = ?)"

        status_sql =
          if insert_only
            "SELECT CASE WHEN EXISTS (SELECT 1 FROM #{quoted_table} WHERE id = ?) " \
              "THEN 'conflicted' ELSE 'inserted' END AS status"
          else
            "SELECT CASE WHEN EXISTS (SELECT 1 FROM #{quoted_table} WHERE id = ?) " \
              "THEN 'replaced' ELSE 'inserted' END AS status"
          end

        # `mirrors` is nullable; see `append`.
        encoded_mirrors = entry.mirrors && JSON.generate(entry.mirrors)

        entry_sql, entry_binds =
          if insert_only
            [
              "INSERT INTO #{quoted_entry_table} (aggregate_id, operation, state, mirrors) " \
              "SELECT ?, ?, ?, ? #{not_exists}",
              [entry.id, entry.operation, state_json(entry.state), encoded_mirrors, entry.id.to_s]
            ]
          else
            [
              "INSERT INTO #{quoted_entry_table} (aggregate_id, operation, state, mirrors) VALUES (?, ?, ?, ?)",
              [entry.id, entry.operation, state_json(entry.state), encoded_mirrors]
            ]
          end

        aggregate_sql, aggregate_binds =
          if insert_only
            [
              "INSERT INTO #{quoted_table} (#{columns.join(", ")}) SELECT #{slots} #{not_exists}",
              values + [entry.id.to_s]
            ]
          else
            [
              "INSERT OR REPLACE INTO #{quoted_table} (#{columns.join(", ")}) VALUES (#{slots})",
              values
            ]
          end

        results = @db.batch([
                              [status_sql, [entry.id.to_s]],
                              [entry_sql, entry_binds],
                              [aggregate_sql, aggregate_binds]
                            ])

        results.fetch(0).fetch(0).fetch("status").to_sym
      end

      def delete(id)
        entry = Ports::Persistence::Entry.new(operation: "delete", id: id.to_s, state: nil)
        append(entry)
        project(entry)
        true
      end

      def record_event(event)
        @db.execute(
          "INSERT INTO events (name, aggregate, aggregate_id, payload, occurred_at) VALUES (?, ?, ?, ?, ?)",
          [event.name, event.aggregate, event.id.to_s, JSON.generate(event.payload), event.occurred_at]
        )
      end

      # Every recorded event in the shared `events` table, not only this aggregate's.
      def events
        @db.execute("SELECT * FROM events ORDER BY id").map do |row|
          Runtime::Event.new(
            name:        row["name"],
            aggregate:   row["aggregate"],
            id:          row["aggregate_id"],
            payload:     JSON.parse(row["payload"], symbolize_names: true),
            occurred_at: row["occurred_at"]
          )
        end
      end

      # One record's recorded events, oldest first — pushed down as a `WHERE` clause
      # (`hecks_events_aggregate_id_idx`) instead of filtering `#events`'s whole-table read.
      def events_for(aggregate:, id:)
        @db.execute(
          "SELECT * FROM events WHERE aggregate = ? AND aggregate_id = ? ORDER BY id",
          [aggregate, id.to_s]
        ).map do |row|
          Runtime::Event.new(
            name:        row["name"],
            aggregate:   row["aggregate"],
            id:          row["aggregate_id"],
            payload:     JSON.parse(row["payload"], symbolize_names: true),
            occurred_at: row["occurred_at"]
          )
        end
      end

      # Persists a saga's checkpointed state as one D1 statement.
      #
      # @param process_manager [String, Symbol] the process manager's name
      # @param correlation [String, Object] the instance's correlation value, stored as
      #   `correlation.to_s`
      # @param state [String, Symbol] the saga's current state name
      # @param memory [Hash] the saga's memory; must be JSON-serializable
      # @param completed_compensations [Array] the ledger of completed compensable legs; must
      #   be JSON-serializable
      # @return [Array] the statement's empty result rows; callers ignore it
      # @raise [Runtime::WiringError] if D1 rejects the statement
      def save_saga(process_manager:, correlation:, state:, memory:, completed_compensations: [])
        @db.execute(
          "INSERT OR REPLACE INTO hecks_saga_instances (domain, process_manager, correlation, state, memory, " \
          "completed_compensations) VALUES (?, ?, ?, ?, ?, ?)",
          [@domain, process_manager.to_s, correlation.to_s, state.to_s, JSON.generate(memory),
           JSON.generate(completed_compensations)]
        )
      end

      def delete_saga(process_manager:, correlation:)
        @db.execute(
          "DELETE FROM hecks_saga_instances WHERE domain = ? AND process_manager = ? AND correlation = ?",
          [@domain, process_manager.to_s, correlation.to_s]
        )
      end

      # Yields each checkpointed saga of this domain, for `Registry#rehydrate_sagas!`.
      def each_saga
        return enum_for(:each_saga) unless block_given?

        @db.execute(
          "SELECT process_manager, correlation, state, memory, completed_compensations " \
          "FROM hecks_saga_instances WHERE domain = ?",
          [@domain]
        ).each do |row|
          yield row["process_manager"], row["correlation"], row["state"],
                JSON.parse(row["memory"], symbolize_names: true),
                JSON.parse(row["completed_compensations"] || "[]", symbolize_names: true)
        end
      end

      private

      # SqlQueryBuilder dialect hooks, copied from Sqlite's private methods.
      def select_list = "*"
      def from_relation = quoted_table
      def dialect_name = "D1"
      def empty_in_clause = "0"

      def placeholder(binds, value)
        binds << value
        "?"
      end

      def contains_clause(expression, placeholder)
        "instr(#{expression}, #{placeholder}) > 0"
      end

      def list_contains_clause(column, member, placeholder)
        target = member.empty? ? "json_each.value" : "json_extract(json_each.value, '$.#{member}')"
        "EXISTS (SELECT 1 FROM json_each(#{quote_ident(column)}) WHERE #{target} = #{placeholder})"
      end

      def plain_column(name) = quote_ident(name)

      def nested_expression(name, path, member)
        json_path = path.empty? ? "$.#{member || "value"}" : "$.#{path.join(".")}"
        "json_extract(#{quote_ident(name)}, '#{json_path}')"
      end

      # SQLite has no bare OFFSET; LIMIT -1 is its unbounded spelling.
      def unbounded_limit = " LIMIT -1"

      def order_clause(order_by, policy)
        QuerySpecification::Common::NullPolicy.sql_order(query_expression(order_by.field), order_by.direction, policy)
      end

      def execute_query(sql, binds)
        @db.execute(sql, binds).map { |row| Runtime::Instance.new(aggregate: @aggregate, id: row["id"], state: decode(row)) }
      end

      def quote_ident(name)
        %("#{name.to_s.gsub('"', '""')}")
      end

      def quoted_table = quote_ident(table)
      def entry_table = "#{table}_entries"
      def quoted_entry_table = quote_ident(entry_table)
    end
  end
end
