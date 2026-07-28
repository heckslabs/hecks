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

        create_aggregate_table!
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

      def save(instance)
        columns = (["id"] + @aggregate.attributes.map { |a| a.name.to_s }).map { |c| quote_ident(c) }
        values  = [instance.id.to_s] + @aggregate.attributes.map { |a| encode(a, instance[a.name]) }
        slots   = Array.new(columns.size, "?").join(", ")

        @db.execute(
          "INSERT OR REPLACE INTO #{quoted_table} (#{columns.join(', ')}) VALUES (#{slots})",
          values
        )
        instance
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

      def quoted_table = quote_ident(table)

      def resolve_path(settings, root)
        declared = settings[:database] || settings["database"] || "data/#{table}.db"
        return declared if declared.start_with?("/")

        File.join(root || Dir.pwd, declared)
      end

      def create_aggregate_table!
        columns = @aggregate.attributes.map { |attr| "#{quote_ident(attr.name)} #{sql_type(attr)}" }
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

      def sql_type(attr)
        return "TEXT" if attr.list?

        SQL_TYPES.fetch(attr.type, "TEXT")
      end

      def encode(attr, value)
        return JSON.generate(value || []) if attr.list?
        return JSON.generate(value) if value.is_a?(Hash)

        value
      end

      def decode(row)
        @aggregate.attributes.each_with_object({}) do |attr, state|
          raw = row[attr.name.to_s]
          state[attr.name] =
            if attr.list?
              raw ? JSON.parse(raw, symbolize_names: true) : []
            elsif value_object?(attr)
              raw ? JSON.parse(raw, symbolize_names: true) : nil
            else
              raw
            end
        end
      end

      def value_object?(attr)
        !attr.list? && !@aggregate.value_object(attr.type).nil?
      end
    end
  end
end
