require "json"
require "fileutils"

require_relative "sql_query_builder"
require_relative "sqlite/schema_builder"
require_relative "sqlite/codec"
require_relative "sqlite/dialect"
require_relative "sqlite/reads"
require_relative "sqlite/writes"
require_relative "sqlite/outbox_operations"
require_relative "sqlite/saga_operations"
require_relative "sqlite/event_log"
require_relative "../../ports/persistence/append_only"
require_relative "../../query_specification/common/null_policy"
require_relative "../../query_specification/common/order_by"
require_relative "../../runtime/errors"
require_relative "../../runtime/event"
require_relative "../../runtime/outbox"
require_relative "../../runtime/instance"

module Hecks
  module Adapters
    # The SQLite store: one table per aggregate head, an append-only entry
    # table beside it. The DDL lives in sqlite/schema_builder.rb, the
    # column codec in sqlite/codec.rb, and the query compilation is the
    # shared SqlQueryBuilder — this file supplies only SQLite's dialect.
    # The read path (`Reads`), the write path (`Writes`), the outbox
    # (`OutboxOperations`), the optional saga capability
    # (`SagaOperations`) and the shared `events` table (`EventLog`) each
    # live in their own sibling file, split out only to keep this class
    # under its line budget.
    class Sqlite
      include SqlQueryBuilder
      include SchemaBuilder
      include Codec
      include Dialect
      include Reads
      include Writes
      include OutboxOperations
      include SagaOperations
      include EventLog

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
        # **Lazy, on purpose** — a domain that never wires Sqlite should never
        # need the gem installed. `require "hecks"` alone must not
        # force a database client library nobody asked for.
        require "sqlite3"

        @aggregate = aggregate
        @path      = resolve_path(settings, root)
        @domain    = resolve_domain(settings, aggregate)
        open_database!
        create_tables!
      end

      # Runs the block inside one SQLite transaction, joining an already-open one.
      #
      # **Re-entrant on purpose** — `atomic_put` opens its own transaction
      # and `Interpreting#run_dispatch_order` opens one around the whole
      # save+emit pair; SQLite3 refuses a BEGIN inside a BEGIN, so the
      # inner call joins the outer one instead. Same shape Postgres uses.
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

      # Journals a delete and removes the row, whether or not a row exists. The two
      # statements share a transaction only when the caller has one open.
      #
      # @param id [String, Object] the aggregate identity, journalled as `id.to_s`
      # @return [Boolean] always true
      # @raise [SQLite3::Exception] if either statement fails
      def delete(id)
        entry = Ports::Persistence::Entry.new(operation: "delete", id: id.to_s, state: nil)
        append(entry)
        project(entry)
        true
      end

      # Claims a pending outbox row with a compare-and-set update, counting the attempt.
      #
      # These two stay directly on `Sqlite` rather than in
      # `sqlite/outbox_operations.rb` alongside the rest of the outbox
      # operations — `.rubocop_todo.yml`'s own `Naming/PredicateMethod`
      # exclusion already names this file for their boolean, non-`?`
      # names, and moving them would need that todo entry extended,
      # which is out of scope here.
      #
      # @param id [Integer] the row id `outbox_enqueue` assigned
      # @return [Boolean] true when the row was pending and is now claimed; false when it is
      #   unknown or another claimer got there first
      # @raise [SQLite3::Exception] if the update fails
      def outbox_claim(id)
        @db.execute(
          "UPDATE hecks_outbox SET status = 'claimed', attempts = attempts + 1, claimed_at = ? " \
          "WHERE id = ? AND status = 'pending'",
          [Time.now.utc.iso8601, id]
        )
        @db.changes == 1
      end

      # Records a delivery outcome and its settle time on an outbox row, whatever status it
      # held.
      #
      # @param id [Integer] the row id `outbox_enqueue` assigned
      # @param status [String, Symbol] the new status, one of `Runtime::Outbox::STATUSES`;
      #   not validated here
      # @param error [String, nil] the failure description, or nil to store NULL
      # @return [Boolean] true when exactly one row was updated; false when no row has `id`
      # @raise [SQLite3::Exception] if the update fails
      def outbox_settle(id, status:, error: nil)
        @db.execute(
          "UPDATE hecks_outbox SET status = ?, error = ?, settled_at = ? WHERE id = ?",
          [status.to_s, error, Time.now.utc.iso8601, id]
        )
        @db.changes == 1
      end

      private

      def resolve_domain(settings, aggregate)
        # The optional saga-persistence capability's own scoping column
        # (§2/§4) — falls back to the aggregate's own name for a
        # directly-instantiated adapter (specs), same fallback shape
        # Postgres's own @domain already uses.
        (
          if settings.key?(:domain)
            settings[:domain]
          elsif settings.key?("domain")
            settings["domain"]
          else
            aggregate.name
          end
        ).to_s
      end

      def open_database!
        FileUtils.mkdir_p(File.dirname(@path))
        @db = SQLite3::Database.new(@path)
        @db.results_as_hash = true
        # The append is the recovery commit point. Keep SQLite's fsync policy
        # explicit instead of inheriting a process-wide pragma choice.
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
      end

      def resolve_path(settings, root)
        declared =
          if settings.key?(:database)
            settings[:database]
          elsif settings.key?("database")
            settings["database"]
          else
            "data/#{table}.db"
          end
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
