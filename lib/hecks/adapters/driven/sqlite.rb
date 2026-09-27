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
        @domain = (
          if settings.key?(:domain)
            settings[:domain]
          elsif settings.key?("domain")
            settings["domain"]
          else
            aggregate.name
          end
        ).to_s

        FileUtils.mkdir_p(File.dirname(@path))
        @db = SQLite3::Database.new(@path)
        @db.results_as_hash = true
        # The append is the recovery commit point, so the fsync policy is explicit.
        @db.execute("PRAGMA synchronous = FULL")

        create_aggregate_table!
        create_entry_table!
        ensure_entry_operation_column!
        ensure_entry_mirrors_column!
        create_event_table!
        create_saga_table!
        create_outbox_table!
        create_checkpoint_table!
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

      # Reads the current row for one aggregate identity.
      #
      # @param id [String, Object] the aggregate identity, bound as `id.to_s`
      # @return [Runtime::Instance, nil] the decoded record, or nil when no row has that id
      # @raise [SQLite3::Exception] if the statement fails
      def find(id)
        row = @db.get_first_row("SELECT * FROM #{quoted_table} WHERE id = ?", [id.to_s])
        return nil unless row

        Runtime::Instance.new(aggregate: @aggregate, id: row["id"], state: decode(row))
      end

      # Lists every stored record, ordered by id unless an ordering attribute is given.
      #
      # order_by is a runtime value, so it is checked against the aggregate before use.
      #
      # @param order_by [String, Symbol, nil] attribute (or dotted value-object path) to sort
      #   by; nil orders by id alone
      # @param direction [Symbol, String] `:asc` or `:desc`, case-insensitive; anything else
      #   sorts ascending
      # @return [Array<Runtime::Instance>] the decoded records, `[]` when the table is empty
      # @raise [Runtime::WiringError] if `order_by` names no attribute of the aggregate
      # @raise [SQLite3::Exception] if the statement fails
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

      # Counts the rows in the aggregate's table, deleted records excluded.
      #
      # @return [Integer] number of current records
      # @raise [SQLite3::Exception] if the statement fails
      def count = @db.get_first_value("SELECT COUNT(*) FROM #{quoted_table}").to_i

      # Inserts one journal row, outside any transaction of its own.
      #
      # Stamps the row's assigned `sequence` onto `entry` in place, so a `project` call right
      # after (same object, same transaction) can advance the checkpoint with no extra query.
      #
      # @param entry [Ports::Persistence::Entry] the save or delete to journal; `state` is
      #   encoded through the state codec and `mirrors` stored as JSON, or NULL when nil
      # @return [Ports::Persistence::Entry] the same `entry`, `sequence` now set
      # @raise [SQLite3::Exception] if the insert fails
      def append(entry)
        @db.execute(
          "INSERT INTO #{quoted_entry_table} (aggregate_id, operation, state, mirrors) VALUES (?, ?, ?, ?)",
          # `mirrors` is nullable: an absent hash must bind SQL NULL, not the JSON text "null".
          [entry.id, entry.operation, JSON.generate(Ports::Persistence::StateCodec.encode(@aggregate, entry.state)),
           entry.mirrors && JSON.generate(entry.mirrors)]
        )
        entry.sequence = @db.last_insert_row_id
        entry
      end

      # Replaces or deletes the aggregate's row for one journal entry.
      #
      # @param entry [Ports::Persistence::Entry] the save or delete to materialize
      # @return [Runtime::Instance, Array] for a save, a new instance over the entry's state;
      #   for a delete, the `DELETE` statement's empty result rows
      # @raise [SQLite3::Exception] if the statement fails
      def project(entry)
        advance_checkpoint!(entry.sequence) if entry.sequence
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

      # Reads the whole journal back in append order, for `AppendOnly#recover!` to replay.
      #
      # @return [Array<Ports::Persistence::Entry>] every journalled entry, state decoded
      #   through the state codec and `mirrors` parsed with String keys (nil when none were
      #   stored); a NULL `operation` reads as `"save"`; `[]` when nothing has been appended
      # @raise [SQLite3::Exception] if the statement fails
      # @raise [JSON::ParserError] if a stored `state` or `mirrors` value is not valid JSON
      def entries
        entries_matching(
          "SELECT aggregate_id, operation, state, mirrors, sequence FROM #{quoted_entry_table} ORDER BY sequence"
        )
      end

      # Reads only the journal rows past a given `sequence`, for `AppendOnly#recover!` to replay
      # after a checkpoint instead of the whole journal.
      #
      # @param sequence [Integer] the highest `sequence` already projected; rows at or below it
      #   are skipped
      # @return [Array<Ports::Persistence::Entry>] the journalled entries past `sequence`, in
      #   append order, decoded exactly as `entries` decodes them; `[]` when none are newer
      # @raise [SQLite3::Exception] if the statement fails
      # @raise [JSON::ParserError] if a stored `state` or `mirrors` value is not valid JSON
      def entries_since(sequence)
        entries_matching(
          "SELECT aggregate_id, operation, state, mirrors, sequence FROM #{quoted_entry_table} " \
          "WHERE sequence > ? ORDER BY sequence",
          [sequence]
        )
      end

      # Reads the highest journal `sequence` this table has already had projected into it.
      #
      # @return [Integer] `0` when the table has never been checkpointed (a fresh table, or one
      #   from before this bookkeeping existed) — `entries_since(0)` then reads the whole journal,
      #   matching `entries`' own full replay
      # @raise [SQLite3::Exception] if the statement fails
      def checkpoint
        @db.get_first_value("SELECT last_sequence FROM hecks_checkpoints WHERE aggregate_table = ?", [table]).to_i
      end

      # Reads the highest journal `sequence` compaction has already deleted from this table.
      #
      # @return [Integer] `0` when nothing has ever been compacted
      # @raise [SQLite3::Exception] if the statement fails
      def compacted_through
        @db.get_first_value("SELECT compacted_through FROM hecks_checkpoints WHERE aggregate_table = ?", [table]).to_i
      end

      # Deletes every journal row at or before `through` and records it, so a `:strict`
      # projection catch-up can tell whether it still has the history it needs.
      #
      # Never moves `compacted_through` backwards, and never touches the aggregate's own
      # table — only the journal, which a `:refresh` projection rebuild never needs.
      #
      # @param through [Integer] the highest `sequence` to delete
      # @return [Integer] the number of journal rows deleted
      # @raise [SQLite3::Exception] if a statement fails
      def compact_entries!(through:)
        @db.execute("DELETE FROM #{quoted_entry_table} WHERE sequence <= ?", [through])
        removed = @db.changes
        @db.execute(
          "INSERT INTO hecks_checkpoints (aggregate_table, compacted_through) VALUES (?, ?) " \
          "ON CONFLICT (aggregate_table) DO UPDATE SET " \
          "compacted_through = MAX(compacted_through, excluded.compacted_through)",
          [table, through]
        )
        removed
      end

      # Deletes every row of the aggregate's table and its journal; events, saga rows and
      # outbox rows are left in place.
      #
      # @return [Adapters::Sqlite] self
      # @raise [SQLite3::Exception] if a statement fails
      def reset!
        @db.execute("DELETE FROM #{quoted_table}")
        @db.execute("DELETE FROM #{quoted_entry_table}")
        self
      end

      # Journals and replaces an instance's current state in one transaction.
      #
      # @param instance [Runtime::Instance] the instance to store
      # @return [Runtime::Instance] a new instance over a shallow copy of the saved state
      # @raise [SQLite3::Exception] if either statement fails; the transaction is rolled back
      def save(instance)
        entry = Ports::Persistence::Entry.new(operation: "save", id: instance.id.to_s, state: instance.state.dup)
        transaction do
          append(entry)
          project(entry)
        end
      end

      # Stores an entry and reports whether it inserted, replaced or conflicted.
      #
      # The outcome lookup, journal append and snapshot replacement share one transaction.
      #
      # @param entry [Ports::Persistence::Entry] the save to store
      # @param insert_only [Boolean] when true, an existing row is left untouched
      # @return [Symbol] `:inserted`, `:replaced`, or `:conflicted` when `insert_only` met an
      #   existing row and nothing was written
      # @raise [SQLite3::Exception] if a statement fails; the transaction is rolled back
      def atomic_put(entry, insert_only: false)
        status = nil
        transaction do
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

      # Inserts an emitted event into the database's shared `events` table.
      #
      # @param event [Runtime::Event] the emitted event; `payload` is stored as JSON
      # @return [Array] the insert's empty result rows; callers ignore it
      # @raise [SQLite3::Exception] if the insert fails
      def record_event(event)
        @db.execute(
          "INSERT INTO events (name, aggregate, aggregate_id, payload, occurred_at) VALUES (?, ?, ?, ?, ?)",
          [event.name, event.aggregate, event.id.to_s, JSON.generate(event.payload), event.occurred_at]
        )
      end

      # Reads back every recorded event in insertion order — the database file's whole
      # `events` table, not only this aggregate's rows.
      #
      # @return [Array<Runtime::Event>] the stored events, `payload` parsed with Symbol keys
      #   and `occurred_at` as stored; `[]` when none are recorded
      # @raise [SQLite3::Exception] if the statement fails
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

      # Reads back one record's recorded events, oldest first — pushed down as a `WHERE`
      # clause (`hecks_events_aggregate_id_idx`) instead of filtering `#events`'s whole-table
      # read, since a `corrects` command's history lookup only ever needs this one record.
      #
      # @param aggregate [String] the `"domain::AggregateName"` key events are stored under
      # @param id [String, Object] the record's identity, matched as `id.to_s`
      # @return [Array<Runtime::Event>] the record's stored events; `[]` when it has none
      # @raise [SQLite3::Exception] if the statement fails
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

      # Inserts new outbox rows as pending, skipping any whose `delivery_id` already exists.
      #
      # Rows share this aggregate's database so the enqueue joins the save's transaction, and
      # are keyed by storage name so aggregates sharing a file read back only their own.
      #
      # @param rows [Array<Runtime::Outbox::Row>] rows to enqueue; each accepted row has its
      #   `id` and `status` assigned in place. `row.aggregate` is stored as given
      # @return [Array<Runtime::Outbox::Row>] the rows actually inserted, `[]` when every one
      #   was a duplicate
      # @raise [SQLite3::Exception] if an insert fails
      def outbox_enqueue(rows)
        rows.filter_map do |row|
          @db.execute(
            "INSERT OR IGNORE INTO hecks_outbox (delivery_id, event_uid, aggregate, domain, kind, consumer, event, " \
            "status, attempts, enqueued_at) VALUES (?, ?, ?, ?, ?, ?, ?, 'pending', 0, ?)",
            [row.delivery_id, row.event_uid, row.aggregate, row.domain, row.kind, row.consumer,
             JSON.generate(row.event), Time.now.utc.iso8601]
          )
          next nil if @db.changes.zero?

          row.id = @db.last_insert_row_id
          row.status = "pending"
          row
        end
      end

      # Claims a pending outbox row with a compare-and-set update, counting the attempt.
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

      # Lists the outbox rows whose `aggregate` column equals this adapter's `table`, in
      # enqueue order.
      #
      # @param status [String, Symbol, nil] only rows with this status; nil lists every row
      # @return [Array<Runtime::Outbox::Row>] the matching rows, `event` parsed with Symbol
      #   keys; `[]` when none match
      # @raise [SQLite3::Exception] if the statement fails
      def outbox_rows(status: nil)
        sql   = "SELECT * FROM hecks_outbox WHERE aggregate = ?"
        binds = [table]
        if status
          sql << " AND status = ?"
          binds << status.to_s
        end
        @db.execute("#{sql} ORDER BY id", binds).map { |row| outbox_row(row) }
      end

      # Replaces one saga instance's checkpoint, keyed by domain, process manager and
      # correlation.
      #
      # @param process_manager [String, Symbol] the process manager's name
      # @param correlation [String, Object] the instance's correlation value, stored as
      #   `correlation.to_s`
      # @param state [String, Symbol] the saga's current state name
      # @param memory [Hash] the saga's memory; must be JSON-serializable
      # @param completed_compensations [Array] the ledger of completed compensable legs; must
      #   be JSON-serializable
      # @return [Array] the statement's empty result rows; callers ignore it
      # @raise [SQLite3::Exception] if the statement fails
      def save_saga(process_manager:, correlation:, state:, memory:, completed_compensations: [])
        @db.execute(
          "INSERT OR REPLACE INTO hecks_saga_instances (domain, process_manager, correlation, state, memory, " \
          "completed_compensations) VALUES (?, ?, ?, ?, ?, ?)",
          [@domain, process_manager.to_s, correlation.to_s, state.to_s, JSON.generate(memory),
           JSON.generate(completed_compensations)]
        )
      end

      # Removes a finished saga instance's checkpoint; a missing row is not an error.
      #
      # @param process_manager [String, Symbol] the process manager's name
      # @param correlation [String, Object] the instance's correlation value, matched as
      #   `correlation.to_s`
      # @return [Array] the statement's empty result rows; callers ignore it
      # @raise [SQLite3::Exception] if the statement fails
      def delete_saga(process_manager:, correlation:)
        @db.execute(
          "DELETE FROM hecks_saga_instances WHERE domain = ? AND process_manager = ? AND correlation = ?",
          [@domain, process_manager.to_s, correlation.to_s]
        )
      end

      # Yields every checkpointed saga instance of this adapter's domain, for
      # `Registry#rehydrate_sagas!` to restore at boot.
      #
      # @yieldparam process_manager [String] the process manager's name
      # @yieldparam correlation [String] the instance's correlation value
      # @yieldparam state [String] the saga's state name
      # @yieldparam memory [Hash{Symbol => Object}] the saga's memory, Symbol keys at every depth
      # @yieldparam completed_compensations [Array] the completed-compensation ledger, `[]`
      #   when the column is NULL
      # @return [Enumerator, Array<Hash>] an enumerator over the same five values when no
      #   block is given; otherwise the raw result rows
      # @raise [SQLite3::Exception] if the statement fails
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

      # Shared decode step for `entries`/`entries_since` — runs a query already selecting
      # `aggregate_id, operation, state, mirrors, sequence` and builds one Entry per row.
      def entries_matching(sql, binds = [])
        @db.execute(sql, binds).map do |row|
          state = JSON.parse(row["state"])
          Ports::Persistence::Entry.new(
            operation: row["operation"] || "save",
            id:        row["aggregate_id"],
            state:     Ports::Persistence::StateCodec.decode(@aggregate, state),
            mirrors:   row["mirrors"] && JSON.parse(row["mirrors"]),
            sequence:  row["sequence"].to_i
          )
        end
      end

      # Advances this table's checkpoint to `sequence`, never backwards — two overlapping
      # `project` calls for out-of-order entries must not let an older sequence win.
      def advance_checkpoint!(sequence)
        @db.execute(
          "INSERT INTO hecks_checkpoints (aggregate_table, last_sequence) VALUES (?, ?) " \
          "ON CONFLICT (aggregate_table) DO UPDATE SET " \
          "last_sequence = MAX(last_sequence, excluded.last_sequence)",
          [table, sequence]
        )
      end

      def outbox_row(row)
        Runtime::Outbox::Row.new(
          id: row["id"], delivery_id: row["delivery_id"], event_uid: row["event_uid"], aggregate: row["aggregate"],
          domain: row["domain"], kind: row["kind"], consumer: row["consumer"],
          event: JSON.parse(row["event"], symbolize_names: true), status: row["status"],
          attempts: row["attempts"].to_i, error: row["error"]
        )
      end

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
