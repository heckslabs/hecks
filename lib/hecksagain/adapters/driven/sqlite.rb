require "json"
require "fileutils"

require_relative "sql_query_builder"
require_relative "sqlite/schema_builder"
require_relative "sqlite/codec"
require_relative "../../ports/persistence/append_only"
require_relative "../../query_specification/common/null_policy"
require_relative "../../query_specification/common/order_by"
require_relative "../../runtime/errors"
require_relative "../../runtime/event"
require_relative "../../runtime/instance"

module Hecksagain
  module Adapters
    # The SQLite store: one table per aggregate head, an append-only entry
    # table beside it. The DDL lives in sqlite/schema_builder.rb, the
    # column codec in sqlite/codec.rb, and the query compilation is the
    # shared SqlQueryBuilder — this file supplies only SQLite's dialect.
    class Sqlite
      include SqlQueryBuilder
      include SchemaBuilder
      include Codec

      SQL_TYPES = { "Integer" => "INTEGER", "Float" => "REAL" }.freeze

      attr_reader :aggregate, :path

      def persistence_capabilities = [:atomic_put]

      def initialize(aggregate:, settings: {}, root: nil)
        # LAZY, ON PURPOSE — a domain that never wires Sqlite should never
        # need the gem installed. `require "hecksagain"` alone must not
        # force a database client library nobody asked for.
        require "sqlite3"

        @aggregate = aggregate
        @path      = resolve_path(settings, root)
        # THE OPTIONAL saga-persistence capability's own scoping column
        # (§2/§4) — falls back to the aggregate's own name for a
        # directly-instantiated adapter (specs), same fallback shape
        # Postgres's own @domain already uses.
        @domain    = (settings[:domain] || settings["domain"] || aggregate.name).to_s

        FileUtils.mkdir_p(File.dirname(@path))
        @db = SQLite3::Database.new(@path)
        @db.results_as_hash = true
        # The append is the recovery commit point. Keep SQLite's fsync policy
        # explicit instead of inheriting a process-wide pragma choice.
        @db.execute("PRAGMA synchronous = FULL")

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
      # full reasoning; whitelisted the identical way before it ever
      # reaches order_expression.
      def all(order_by: nil, direction: :asc)
        order_sql = "ORDER BY id"
        if order_by
          name = order_by.to_s.split(".").first
          raise Runtime::WiringError, "#{@aggregate.name} has no attribute #{order_by.inspect} to order by" unless @aggregate.lifecycle&.field.to_s == name || @aggregate.attribute(name)

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
          [entry.id, entry.operation, JSON.generate(entry.state), JSON.generate(entry.mirrors)]
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

      # The outcome lookup, journal append and snapshot replacement share one
      # SQLite transaction. The runtime performs no preliminary find; this
      # adapter-native operation owns both concurrency and outcome reporting.
      def atomic_put(entry, insert_only: false)
        status = nil
        @db.transaction do
          exists = !@db.get_first_value("SELECT 1 FROM #{quoted_table} WHERE id = ?", [entry.id.to_s]).nil?
          if insert_only && exists
            status = :conflicted
            next
          end
          status = exists ? :replaced : :inserted
          append(entry)
          project(entry)
        end
        status
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

      # ── the OPTIONAL saga-persistence capability (§2) — reuses the
      # DDL every SQLite-backed aggregate table already lives beside
      # (`create_saga_table!`, `Sqlite::SchemaBuilder`, shared with D1).
      # SQLite's `resolve_path` defaults to one `.db` file PER
      # AGGREGATE unless a domain shares one `database` setting across
      # its aggregates — since saga persistence resolves through
      # whichever adapter instance backs the domain's FIRST aggregate
      # (`Registry#saga_persistence`), this table ends up living inside
      # THAT one aggregate's own file by default. Correct and durable
      # either way; a domain that wants an obviously-named saga store
      # already gets one by sharing `database` across its aggregates,
      # the recommended, common case.
      def save_saga(process_manager:, correlation:, state:, memory:)
        @db.execute(
          "INSERT OR REPLACE INTO hecks_saga_instances (domain, process_manager, correlation, state, memory) " \
          "VALUES (?, ?, ?, ?, ?)",
          [@domain, process_manager.to_s, correlation.to_s, state.to_s, JSON.generate(memory)]
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
          "SELECT process_manager, correlation, state, memory FROM hecks_saga_instances WHERE domain = ?",
          [@domain]
        ).each do |row|
          yield row["process_manager"], row["correlation"], row["state"],
                JSON.parse(row["memory"], symbolize_names: true)
        end
      end

      private

      # ── SqlQueryBuilder's dialect hooks ─────────────────────────────

      def select_list = "*"
      def from_relation = quoted_table
      def dialect_name = "SQLite"
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

      # SQLite has no bare OFFSET — LIMIT -1 is its own documented
      # unbounded spelling, exactly for this case.
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

      def resolve_path(settings, root)
        declared = settings[:database] || settings["database"] || "data/#{table}.db"
        return declared if declared.start_with?("/")

        File.join(root || Dir.pwd, declared)
      end
    end

    # Port-specific bindings share SQLite's storage mechanics but advertise
    # only one operational contract each.
    class SqlitePersistence < Sqlite; end
  end
end

require_relative "sqlite/projection"
