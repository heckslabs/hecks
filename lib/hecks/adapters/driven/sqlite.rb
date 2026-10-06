require "json"
require "fileutils"

require_relative "sql_query_builder"
require_relative "sqlite/schema_builder"
require_relative "sqlite/codec"
require_relative "sqlite/dialect"
require_relative "sqlite/events"
require_relative "sqlite/journal"
require_relative "sqlite/outbox"
require_relative "sqlite/repository"
require_relative "sqlite/sagas"
require_relative "../../ports/persistence/append_only"
require_relative "../../query_specification/common/null_policy"
require_relative "../../query_specification/common/order_by"
require_relative "../../runtime/errors"
require_relative "../../runtime/event"
require_relative "../../runtime/outbox"
require_relative "../../runtime/instance"

module Hecks
  module Adapters
    # The SQLite store: one table per aggregate head, an append-only entry table beside it.
    # Supplies SQLite's dialect to the shared SqlQueryBuilder.
    class Sqlite
      include SqlQueryBuilder
      include SchemaBuilder
      include Codec
      include Repository
      include Journal
      include Events
      include Outbox
      include Sagas
      include Dialect

      SQL_TYPES = { "Integer" => "INTEGER", "Float" => "REAL" }.freeze

      attr_reader :aggregate, :path

      # Names the optional persistence capabilities `Ports::Persistence::AppendOnly` may rely on.
      #
      # @return [Array<Symbol>] `[:atomic_put]`
      def persistence_capabilities = [:atomic_put]

      # Opens (creating if absent) the database file and its aggregate, journal, event, saga
      # and outbox tables.
      #
      # @param aggregate [Bluebook::Aggregate] the aggregate whose table this adapter owns
      # @param settings [Hash{Symbol, String => Object}] world settings for the binding:
      #   `database` (file path, default `data/<table>.db`) and `domain` (scopes saga rows,
      #   default the aggregate's name), each read under a Symbol or a String key
      # @param root [String, nil] directory a relative `database` path resolves against; nil
      #   means the process working directory
      # @raise [LoadError] if the `sqlite3` gem is not installed
      # @raise [SQLite3::Exception] if the file cannot be opened or a table cannot be created
      def initialize(aggregate:, settings: {}, root: nil)
        # Lazy so a domain that never wires Sqlite does not need the gem installed.
        require "sqlite3"

        @aggregate = aggregate
        @path      = resolve_path(settings, root)
        # Scopes saga rows; falls back to the aggregate's name for a directly built adapter.
        @domain = setting(settings, :domain, aggregate.name).to_s
        open_database
        create_tables!
      end

      # Runs the block inside one SQLite transaction, joining an already-open one.
      #
      # Re-entrant because `atomic_put` and `Interpreting#run_dispatch_order` both open one,
      # and SQLite3 refuses a BEGIN inside a BEGIN.
      #
      # @yield the writes to commit together; an exception raised inside rolls the
      #   outermost transaction back
      # @return [Object] the block's own result
      # @raise [SQLite3::Exception] if `BEGIN`, a statement inside the block, or `COMMIT` fails
      def transaction(&)
        return yield if @db.transaction_active?

        @db.transaction(&)
      end

      # Names the aggregate's table; the journal table and outbox rows are keyed off it.
      #
      # @return [String] the aggregate's snake_case storage name, unquoted
      def table = @aggregate.storage_name

      private

      def open_database
        FileUtils.mkdir_p(File.dirname(@path))
        @db = SQLite3::Database.new(@path)
        @db.results_as_hash = true
        # The append is the recovery commit point, so the fsync policy is explicit.
        @db.execute("PRAGMA synchronous = FULL")
      end

      def create_tables!
        create_aggregate_table!
        create_entry_table!
        ensure_entry_operation_column!
        ensure_entry_mirrors_column!
        create_event_table!
        create_saga_table!
        create_outbox_table!
        create_checkpoint_table!
      end

      # A setting read under its Symbol key, then its String key, then `default`.
      def setting(settings, key, default)
        return settings[key] if settings.key?(key)
        return settings[key.to_s] if settings.key?(key.to_s)

        default
      end

      def resolve_path(settings, root)
        declared = setting(settings, :database, "data/#{table}.db")
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
