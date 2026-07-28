# Sqlite — a persistence adapter backed by a real SQLite database.
#
# The SCHEMA IS PROJECTED from the aggregate IR: one column per declared
# attribute, its SQL type derived from the declared Ruby type, list attributes
# stored as JSON. Nothing about the table is hand-written — the bluebook is the
# single author, and a target that wants data rather than source reads the IR.
#
# The domain never learns any of this. It says `persisted_by("Sqlite")` in the
# hecksagon and the adapter does the rest.
#
#   Sqlite.new(aggregate: pizza_ir, settings: { database: "data/pizzas.db" })
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

      # The aggregate's table name, unquoted — this is also the .db filename
      # stem, so it stays a bare word. SQL wants `quoted_table`.
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

      # The event log is durable too — a purchase you cannot look up tomorrow
      # was never really recorded.
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

      # Quote a SQL identifier (table or column name) so a reserved word —
      # `order`, `group`, `select`, `user` — is a legal identifier instead of
      # a syntax error. SQLite's standard double-quote form, with any embedded
      # quote doubled per the SQL spec.
      #
      # THE COUNTERPART OF rust/sqlite/src/sqlite_mapping.rs `quote_ident`,
      # which had it and this side did not. An aggregate named `Order` — the
      # likeliest name in any shop domain, and one the canonical Pizzas
      # example uses — snakes to the table `order`, which Rust created happily
      # and Ruby refused with a syntax error at boot. Nothing caught it because
      # no aggregate in the corpus is named after a keyword.
      #
      # The identifiers reaching here are internal (a snake_cased aggregate
      # name, or an IR-declared column), so this is a keyword-collision guard,
      # not the injection boundary — that is the `?` bind params.
      def quote_ident(name)
        %("#{name.to_s.gsub('"', '""')}")
      end

      def quoted_table = quote_ident(table)

      def resolve_path(settings, root)
        declared = settings[:database] || settings["database"] || "data/#{table}.db"
        return declared if declared.start_with?("/")

        File.join(root || Dir.pwd, declared)
      end

      # One column per declared attribute — the schema follows the IR.
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

      # Lists become JSON ; everything else takes the declared type's SQL kind.
      def sql_type(attr)
        return "TEXT" if attr.list?

        SQL_TYPES.fetch(attr.type, "TEXT")
      end

      # A VALUE OBJECT IS JSON, whether it arrives alone or in a list.
      #
      # Only lists were serialised, so a scalar attribute declared as a
      # value object reached the driver as a Hash and SQLite answered "no
      # such bind parameter" — a store that could hold `list_of(Money)` but
      # not one Money. It went unnoticed because value objects were never
      # CONSTRUCTED for scalar attributes either : the raw scalar bound
      # fine, so the gap only appeared once the runtime started building
      # them.
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

      # A scalar attribute whose declared type is one of this aggregate's
      # value objects — the ones that round-trip as JSON.
      def value_object?(attr)
        !attr.list? && !@aggregate.value_object(attr.type).nil?
      end
    end
  end
end
