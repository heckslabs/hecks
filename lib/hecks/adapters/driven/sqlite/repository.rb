module Hecks
  module Adapters
    class Sqlite
      # The repository surface: find, list, count, and the journal-then-project writes.
      module Repository
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
          rows = @db.execute("SELECT * FROM #{quoted_table} #{order_sql(order_by, direction)}")
          rows.map { |row| Runtime::Instance.new(aggregate: @aggregate, id: row["id"], state: decode(row)) }
        end

        # Counts the rows in the aggregate's table, deleted records excluded.
        #
        # @return [Integer] number of current records
        # @raise [SQLite3::Exception] if the statement fails
        def count = @db.get_first_value("SELECT COUNT(*) FROM #{quoted_table}").to_i

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
          @db.execute(upsert_sql(quoted_columns), instance_values(instance))
          instance
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
          transaction { status = put_entry(entry, insert_only) }
          status
        end

        # Journals a delete and removes the row, whether or not a row exists. The two
        # statements share a transaction only when the caller has one open.
        #
        # @param id [String, Object] the aggregate identity, journalled as `id.to_s`
        # @return [Boolean] always true
        # @raise [SQLite3::Exception] if either statement fails
        def delete(id) # rubocop:disable Naming/PredicateMethod -- the repository port's verb, not a question
          entry = Ports::Persistence::Entry.new(operation: "delete", id: id.to_s, state: nil)
          append(entry)
          project(entry)
          true
        end

        private

        def order_sql(order_by, direction)
          return "ORDER BY id" unless order_by

          name = order_by.to_s.split(".").first
          unless @aggregate.lifecycle&.field.to_s == name || @aggregate.attribute(name)
            raise Runtime::WiringError,
                  "#{@aggregate.name} has no attribute #{order_by.inspect} to order by"
          end

          spec = QuerySpecification::Common::OrderBy.new(field: order_by, direction: direction)
          "ORDER BY #{order_clause(spec, nil)}"
        end

        def quoted_columns
          (["id"] + persisted_fields.map { |field| field[:name].to_s }).map { |column| quote_ident(column) }
        end

        def upsert_sql(columns)
          slots = Array.new(columns.size, "?").join(", ")
          "INSERT OR REPLACE INTO #{quoted_table} (#{columns.join(", ")}) VALUES (#{slots})"
        end

        def instance_values(instance)
          [instance.id.to_s] + persisted_fields.map { |field| encode_field(field, instance[field[:name]]) }
        end

        def put_entry(entry, insert_only)
          exists = !@db.get_first_value("SELECT 1 FROM #{quoted_table} WHERE id = ?", [entry.id.to_s]).nil?
          return :conflicted if insert_only && exists

          append(entry)
          project(entry)
          exists ? :replaced : :inserted
        end
      end
    end
  end
end
