require "json"
require "net/http"
require "uri"

require_relative "sql_query_builder"
require_relative "sqlite/schema_builder"
require_relative "sqlite/codec"
require_relative "sqlite" # for Sqlite::SchemaBuilder/Sqlite::Codec — see the reuse note below
require_relative "../../ports/persistence/append_only"
require_relative "../../query_specification/common/null_policy"
require_relative "../../query_specification/common/order_by"
require_relative "../../runtime/errors"
require_relative "../../runtime/event"
require_relative "../../runtime/instance"

module Hecks
  module Adapters
    # Cloudflare D1 — SQLite, managed, reached over its REST API rather
    # than a local file. D1 IS SQLite, dialect and all, so this file
    # reuses Sqlite::SchemaBuilder and Sqlite::Codec UNCHANGED (the DDL
    # and the column encode/decode) and SqlQueryBuilder's dialect hooks
    # are copied near-verbatim from sqlite.rb — the only real difference
    # is the transport (D1::Connection, an HTTP call per query, vs a
    # persistent local sqlite3 handle). See sqlite.rb's own header
    # comment: "this file supplies only SQLite's dialect" — true here too.
    class D1
      # THE TRANSPORT — mirrors just the slice of SQLite3::Database's own
      # interface (execute/get_first_row/get_first_value, rows as
      # column-name-keyed hashes) that Sqlite::SchemaBuilder, Sqlite::Codec,
      # and this file's own methods already assume. One stateless HTTP call
      # per execute, not a persistent connection — D1 has no connection to
      # hold open.
      class Connection
        ENDPOINT = "https://api.cloudflare.com/client/v4".freeze

        def initialize(account_id:, database_id:, api_token:)
          @uri = URI("#{ENDPOINT}/accounts/#{account_id}/d1/database/#{database_id}/query")
          @api_token = api_token
        end

        def execute(sql, binds = [])
          response_results({ sql: sql, params: binds }).first.fetch("results", [])
        end

        # D1 batches are SQL transactions: statements execute in order and a
        # failure rolls the entire sequence back. Keep the tuple-shaped local
        # seam small so adapter code and focused fakes do not need to know the
        # REST request envelope.
        # https://developers.cloudflare.com/d1/worker-api/d1-database/#batch
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

        # `messages` is the whole-response :errors fallback, tried LAST —
        # a per-statement `failed["error"]`/`failed["message"]` (checked
        # by key presence, not truthiness, so an explicit `nil` still
        # counts as "the key was there") is always more specific to WHICH
        # statement failed, when either is present.
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

      def initialize(aggregate:, settings: {}, root: nil)
        @aggregate = aggregate

        account_id  = settings.key?(:account_id)  ? settings[:account_id]  : settings["account_id"]
        database_id = settings.key?(:database_id) ? settings[:database_id] : settings["database_id"]
        api_token   = settings.key?(:api_token)   ? settings[:api_token]   : settings["api_token"]
        { "account_id" => account_id, "database_id" => database_id, "api_token" => api_token }.each do |name, value|
          raise Runtime::WiringError, "D1 needs a #{name.inspect} in its world settings" if value.to_s.empty?
        end

        @db = Connection.new(account_id: account_id, database_id: database_id, api_token: api_token)
        # THE OPTIONAL saga-persistence capability's own scoping column
        # (§2/§4) — D1's domain isolation is by whole-database identity
        # (one D1 database per domain in practice), so unlike Sqlite's
        # own per-aggregate-file default, there's no "which file does
        # this end up in" ambiguity here: every aggregate on D1 within a
        # domain already shares one database.
        @domain = (
          if settings.key?(:domain)
            settings[:domain]
          elsif settings.key?("domain")
            settings["domain"]
          else
            aggregate.name
          end
        ).to_s

        # No PRAGMA synchronous here, unlike Sqlite — D1 is a managed
        # durable service; there is no local fsync policy for a caller to
        # tune, and the query endpoint has no PRAGMA write-access to it.
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

      # order_by IS A RUNTIME VALUE — see postgres.rb's own all for the
      # full reasoning; whitelisted the identical way, same order_clause
      # Sqlite's own all reuses (D1 speaks the identical dialect).
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
          # `mirrors` (unlike `state`) is a NULLABLE column — an absent
          # mirrors hash must bind a real SQL NULL, not the four-character
          # JSON text `"null"` (`JSON.generate(nil)`), or a future `IS NULL`
          # check against it would never match. Same guard `postgres_era.rb`
          # already uses for its own journal's `mirrors` column.
          [entry.id, entry.operation, JSON.generate(entry.state), entry.mirrors && JSON.generate(entry.mirrors)]
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
          "INSERT OR REPLACE INTO #{quoted_table} (#{columns.join(', ')}) VALUES (#{slots})",
          values
        )
        instance
      end

      def entries
        @db.execute("SELECT aggregate_id, operation, state, mirrors FROM #{quoted_entry_table} ORDER BY sequence").map do |row|
          state = JSON.parse(row["state"])
          Ports::Persistence::Entry.new(
            operation: row["operation"] || "save",
            id:        row["aggregate_id"],
            state:     state&.transform_keys(&:to_sym),
            mirrors:   row["mirrors"] && JSON.parse(row["mirrors"])
          )
        end
      end

      def reset!
        @db.execute("DELETE FROM #{quoted_table}")
        @db.execute("DELETE FROM #{quoted_entry_table}")
        self
      end

      def save(instance)
        entry = Ports::Persistence::Entry.new(operation: "save", id: instance.id.to_s, state: instance.state.dup)
        append(entry)
        project(entry)
      end

      # Classification, durable journal append and current-state projection
      # are one D1 batch transaction and therefore one HTTP request. The first
      # statement supplies the outcome from database state inside that same
      # transaction; the runtime performs no preliminary find.
      #
      # `insert_only:` used to spend a SEPARATE, EARLIER round trip finding
      # out whether the row existed before ever building the batch — a real
      # TOCTOU gap (two concurrent creates at the same identity could both
      # pass that check before either wrote). D1's batch has no conditional
      # BRANCH of its own, true, but it does not need one: a batch's own
      # statements already execute in order, atomically, as one transaction
      # (Connection#batch's own comment) — the exact guarantee the single-
      # connection adapters' own `@db.transaction do ... end` gets locally.
      # So the existence check moves INSIDE the batch as its own first
      # statement, and the two writes are individually gated with `WHERE NOT
      # EXISTS (...)` against that same table, evaluated in the same
      # transaction — a row that already existed makes both writes into
      # real, zero-row no-ops rather than skipping them from the Ruby side,
      # matching Sqlite#atomic_put's `next` (skip append AND project both,
      # together) with no second HTTP call and no gap for another writer to
      # land in between the check and the write.
      # Three SQL statements, built here and batched together as ONE
      # transaction below — see the comment above on the real TOCTOU gap
      # this exact shape closes (the existence check moved INSIDE the
      # batch, not run as a separate earlier round trip). Splitting the
      # per-statement builders out would still need columns/values/slots/
      # not_exists/quoted_table threaded into each, and would separate
      # three pieces of ONE atomic batch across methods with no single
      # place left to see that they are, together, the fix.
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

        # `mirrors` is NULLABLE (unlike `state`) — see `append`'s own comment.
        encoded_mirrors = entry.mirrors && JSON.generate(entry.mirrors)

        entry_sql, entry_binds =
          if insert_only
            [
              "INSERT INTO #{quoted_entry_table} (aggregate_id, operation, state, mirrors) " \
              "SELECT ?, ?, ?, ? #{not_exists}",
              [entry.id, entry.operation, JSON.generate(entry.state), encoded_mirrors, entry.id.to_s]
            ]
          else
            [
              "INSERT INTO #{quoted_entry_table} (aggregate_id, operation, state, mirrors) VALUES (?, ?, ?, ?)",
              [entry.id, entry.operation, JSON.generate(entry.state), encoded_mirrors]
            ]
          end

        aggregate_sql, aggregate_binds =
          if insert_only
            [
              "INSERT INTO #{quoted_table} (#{columns.join(', ')}) SELECT #{slots} #{not_exists}",
              values + [entry.id.to_s]
            ]
          else
            [
              "INSERT OR REPLACE INTO #{quoted_table} (#{columns.join(', ')}) VALUES (#{slots})",
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

      # ── the OPTIONAL saga-persistence capability (§2) — reuses the DDL
      # `Sqlite::SchemaBuilder` already shares with Sqlite (`d1.rb`'s own
      # file header). Same `?`-placeholder shape every other write here
      # already uses through `Connection#execute`.
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

      # ── SqlQueryBuilder's dialect hooks — identical to Sqlite's, since
      # D1 speaks the same dialect (copied, not shared by module include,
      # because Sqlite's own copies are private instance methods on a
      # different class — see the file header) ───────────────────────
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
        json_path = path.empty? ? "$.#{member || 'value'}" : "$.#{path.join('.')}"
        "json_extract(#{quote_ident(name)}, '#{json_path}')"
      end

      # SQLite (and D1, the same engine) has no bare OFFSET — LIMIT -1 is
      # its own documented unbounded spelling, exactly for this case.
      def unbounded_limit = " LIMIT -1"

      def order_clause(order_by, policy)
        QuerySpecification::Common::NullPolicy.sql_order(query_expression(order_by.field), order_by.direction, policy)
      end

      def execute_query(sql, binds)
        @db.execute(sql, binds).map { |row| Runtime::Instance.new(aggregate: @aggregate, id: row["id"], state: decode(row)) }
      end

      # ── the rest of the dialect ─────────────────────────────────────

      def quote_ident(name)
        %("#{name.to_s.gsub('"', '""')}")
      end

      def quoted_table = quote_ident(table)
      def entry_table = "#{table}_entries"
      def quoted_entry_table = quote_ident(entry_table)
    end
  end
end
