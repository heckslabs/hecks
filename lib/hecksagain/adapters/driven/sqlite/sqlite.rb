require "sqlite3"
require "json"
require "fileutils"

module Hecksagain
  module Adapters
    class Sqlite
      SQL_TYPES = { "Integer" => "INTEGER", "Float" => "REAL" }.freeze

      attr_reader :aggregate, :path

      def initialize(aggregate:, settings: {}, root: nil)
        @aggregate = aggregate
        @path      = resolve_path(settings, root)

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
      end

      def table = @aggregate.storage_name

      def find(id)
        row = @db.get_first_row("SELECT * FROM #{quoted_table} WHERE id = ?", [id.to_s])
        return nil unless row

        Runtime::Instance.new(aggregate: @aggregate, id: row["id"], state: decode(row))
      end

      def all
        @db.execute("SELECT * FROM #{quoted_table} ORDER BY id").map do |row|
          Runtime::Instance.new(aggregate: @aggregate, id: row["id"], state: decode(row))
        end
      end

      def count = @db.get_first_value("SELECT COUNT(*) FROM #{quoted_table}").to_i

      def query(declared, args = {}, context: {})
        sql = "SELECT * FROM #{quoted_table}"
        clauses = []
        binds = []
        declared.wheres.each do |clause|
          value = query_value(clause.value, args)
          expression = query_expression(clause.field, value: value)
          if (null_predicate = QuerySpecification::Common::NullPolicy.sql_predicate(expression, clause.op, value))
            clauses << null_predicate.first
            next
          end
          case clause.op.to_s
          when "eq", "ne", "gt", "gte", "lt", "lte"
            clauses << "#{expression} #{%w[eq ne gt gte lt lte].index(clause.op.to_s) == 0 ? '=' : { 'ne' => '<>', 'gt' => '>', 'gte' => '>=', 'lt' => '<', 'lte' => '<=' }.fetch(clause.op.to_s)} ?"
            binds << value
          when "contains"
            clauses << "instr(#{expression}, ?) > 0"
            binds << value.to_s
          when "in"
            # The same comma-separated convention every other where-clause
            # comparator uses (Ports::Query::InMemory, QueryInterpreter,
            # Rust's dispatcher.rs) — see QuerySpecification.numeric_literal's
            # neighbourhood for why a literal arrives as text at all.
            members = value.to_s.split(",").map(&:strip).reject(&:empty?)
            if members.empty?
              clauses << "0"
            else
              clauses << "#{expression} IN (#{members.map { '?' }.join(', ')})"
              binds.concat(members)
            end
          else
            raise ArgumentError, "SQLite query adapter does not support #{clause.op.inspect}"
          end
        end
        sql << " WHERE #{clauses.join(' AND ')}" unless clauses.empty?
        if declared.order_by
          sql << " ORDER BY #{QuerySpecification::Common::NullPolicy.sql_order(query_expression(declared.order_by.field), declared.order_by.direction, declared.null_semantics)}"
        else
          sql << " ORDER BY id"
        end
        if declared.limit
          sql << " LIMIT ?"
          binds << query_value(declared.limit.value, args).to_i
        end
        if declared.offset
          sql << " OFFSET ?"
          binds << query_value(declared.offset.value, args).to_i
        end
        @db.execute(sql, binds).map { |row| Runtime::Instance.new(aggregate: @aggregate, id: row["id"], state: decode(row)) }
      end

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

      private

      def quote_ident(name)
        %("#{name.to_s.gsub('"', '""')}")
      end

      def query_expression(field, value: nil)
        name, *path = field.to_s.split(".")
        attribute = @aggregate.attribute(name)
        column = quote_ident(name)
        return column if path.empty? && @aggregate.lifecycle&.field.to_s == name
        return column if path.empty? && attribute && !value_object?(attribute) && !attribute.reference?

        value_path = if path.empty? && value
                       hash = value.is_a?(Runtime::Value) ? value.to_h : value
                       numeric = hash.is_a?(Hash) && hash.find { |_key, item| item.is_a?(Numeric) }
                       numeric ? "$.#{numeric.first}" : nil
                       end
        value_path ||= if path.empty? && attribute && value_object?(attribute)
                         object = @aggregate.value_object(attribute.type)
                         numeric = object.attributes.find { |field| %w[Integer Float].include?(field.type) }
                         numeric && "$.#{numeric.name}"
                       end
        json_path = path.empty? ? (value_path || "$.value") : "$.#{path.join('.')}"
        "json_extract(#{column}, '#{json_path}')"
      end

      def query_value(value, args)
        value = args[value] if value.is_a?(Symbol)
        hash = value.is_a?(Runtime::Value) ? value.to_h : value
        return hash.find { |_key, item| item.is_a?(Numeric) }&.last if hash.is_a?(Hash)

        Runtime::Value.scalar(value)
      rescue Runtime::TypeMismatch
        value.is_a?(Hash) && value.size == 1 ? value.values.first : value
      end

      def quoted_table = quote_ident(table)
      def entry_table = "#{table}_entries"
      def quoted_entry_table = quote_ident(entry_table)

      def resolve_path(settings, root)
        declared = settings[:database] || settings["database"] || "data/#{table}.db"
        return declared if declared.start_with?("/")

        File.join(root || Dir.pwd, declared)
      end

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

      def encode(attr, value)
        return JSON.generate(value || []) if attr.list?
        return JSON.generate(value) if value.is_a?(Hash) || value.is_a?(Runtime::Value)

        value
      end

      def encode_field(field, value)
        return value unless field[:attribute]

        encode(field[:attribute], value)
      end

      def decode(row)
        persisted_fields.each_with_object({}) do |field, state|
          attr = field[:attribute]
          unless attr
            state[field[:name]] = row[field[:name].to_s]
            next
          end
          raw = row[attr.name.to_s]
          state[attr.name] =
            if attr.list?
              raw ? JSON.parse(raw, symbolize_names: true) : []
            elsif value_object?(attr) || attr.reference?
              raw ? JSON.parse(raw, symbolize_names: true) : nil
            else
              raw
            end
        end
      end

      def value_object?(attr)
        !attr.list? && !@aggregate.value_object(attr.type).nil?
      end

      def persisted_fields
        fields = @aggregate.attributes.reject { |attribute| attribute.name == :id }.map do |attribute|
          { name: attribute.name, attribute: attribute, sql_type: sql_type(attribute) }
        end
        lifecycle = @aggregate.lifecycle
        if lifecycle && !fields.any? { |field| field[:name] == lifecycle.field }
          fields << { name: lifecycle.field, attribute: nil, sql_type: "TEXT" }
        end
        fields
      end
    end

    # Port-specific bindings share SQLite's storage mechanics but advertise
    # only one operational contract each.
    class SqlitePersistence < Sqlite; end
    class SqliteProjection < Sqlite
      # Older authoritative journals stored one-field value objects as their
      # scalar identity. Accept that durable representation while building a
      # new read store; normal command writes still require object payloads.
      def project(entry)
        return @db.execute("DELETE FROM #{quoted_table} WHERE id = ?", [entry.id]) if entry.delete?

        columns = (["id"] + persisted_fields.map { |field| field[:name].to_s }).map { |column| quote_ident(column) }
        values  = [entry.id.to_s] + persisted_fields.map { |field| encode_field(field, entry.state[field[:name]]) }
        @db.execute("INSERT OR REPLACE INTO #{quoted_table} (#{columns.join(', ')}) VALUES (#{Array.new(columns.size, '?').join(', ')})", values)
        entry
      end

      # Execute a declared read model against the projected aggregate-head
      # tables. The report shape is assembled from SQL-selected rows, rather
      # than scanning repositories and matching references in Ruby.
      def query_read_model(_domain, model, args, bluebook = nil)
        raise ArgumentError, "projection query needs its domain bluebook" unless bluebook

        # The REFERENCE's own shape, read the same way ReadModelInterpreter
        # reads it — not the identity unwrap, which is gone : an identity is
        # declared as a path and followed.
        reference_id = Runtime::Value.reference_id(args.fetch(model.reference_name))
        reports = {}
        model.aggregate_heads.each do |head|
          aggregate = bluebook.aggregate(head[:aggregate])
          rows = if head[:aggregate] == model.reference_target
                   [select_projected(aggregate, reference_id)].compact
                 else
                   select_related(aggregate, model.reference_target, reference_id)
                 end
          reports[head[:as]] = if head[:many]
                                 rows.map { |row| Runtime::Value.materialize(row.to_h) }
                               else
                                 rows.first && Runtime::Value.materialize(rows.first.to_h)
                               end
        end
        [reports]
      end

      private

      def select_projected(aggregate, id)
        row = @db.get_first_row("SELECT * FROM #{quote_ident(aggregate.storage_name)} WHERE id = ?", [id.to_s])
        row && projected_instance(aggregate, row)
      end

      def select_related(aggregate, target, id)
        references = aggregate.attributes.select do |attribute|
          attribute.reference? && attribute.type.target_name == target.to_s
        end
        return [] if references.empty?

        clauses = references.map do |attribute|
          column = quote_ident(attribute.name)
          "(json_extract(#{column}, '$.value') = ? OR #{column} = ?)"
        end
        bind = references.flat_map { [id.to_s, id.to_s] }
        @db.execute("SELECT * FROM #{quote_ident(aggregate.storage_name)} WHERE #{clauses.join(' OR ')} ORDER BY id", bind)
           .map { |row| projected_instance(aggregate, row) }
      end

      def projected_instance(aggregate, row)
        Runtime::Instance.new(aggregate: aggregate, id: row["id"], state: decode_for(aggregate, row))
      end

      def decode_for(aggregate, row)
        fields = aggregate.attributes.map { |attribute| [attribute.name, attribute] }
        if (lifecycle = aggregate.lifecycle) && !fields.any? { |name, _| name == lifecycle.field }
          fields << [lifecycle.field, nil]
        end
        fields.each_with_object({}) do |(name, attribute), state|
          raw = row[name.to_s]
          state[name] = if attribute.nil?
                          raw
                        elsif attribute.list?
                                   raw ? JSON.parse(raw, symbolize_names: true) : []
                                 elsif !aggregate.value_object(attribute.type).nil? || attribute.reference?
                                   raw ? JSON.parse(raw, symbolize_names: true) : nil
                                 else
                                   raw
                                 end
        end
      end
    end
  end
end
