module Hecks
  module Adapters
    class Postgres
      # The repository surface: find, list, count, and the journal-then-project writes.
      module Repository
        # Reads the current row for one aggregate identity, stamped with its stored version.
        #
        # @param id [String, Object] the aggregate identity, bound as `id.to_s`
        # @return [Runtime::Instance, nil] the decoded record with `version` set, or nil when
        #   no row has that id
        # @raise [PG::Error] if the statement fails; a `PG::ConnectionBad` also triggers a
        #   reconnect for the next caller
        def find(id)
          result = pg_exec_params("SELECT * FROM #{quoted_table} WHERE id = $1", [id.to_s])
          return nil if result.ntuples.zero?

          instance_from_row(result[0])
        end

        # Lists every stored record, ordered by id unless an ordering attribute is given.
        #
        # order_by is a runtime value, whitelisted the same way Sqlite#all does.
        #
        # @param order_by [String, Symbol, nil] attribute (or dotted value-object path) to sort
        #   by, with id as the tie-break; nil orders by id alone
        # @param direction [Symbol, String] `:asc` or `:desc`, case-insensitive; anything else
        #   sorts ascending
        # @return [Array<Runtime::Instance>] the decoded records with `version` set, `[]` when
        #   the table is empty
        # @raise [Runtime::WiringError] if `order_by` names no attribute of the aggregate
        # @raise [PG::Error] if the statement fails
        def all(order_by: nil, direction: :asc)
          pg_exec("SELECT * FROM #{quoted_table} #{order_sql(order_by, direction)}").map { |row| instance_from_row(row) }
        end

        # Counts the rows in the aggregate's table, deleted records excluded.
        #
        # @return [Integer] number of current records
        # @raise [PG::Error] if the statement fails
        def count = pg_exec("SELECT COUNT(*) FROM #{quoted_table}")[0]["count"].to_i

        # Upserts or deletes the aggregate's row for one journal entry, bumping its version.
        #
        # `expected_version` requests optimistic-concurrency CAS; nil back means it didn't match.
        #
        # @param entry [Ports::Persistence::Entry] the save or delete to materialize
        # @param expected_version [Integer, nil] the `hecks_version` the row must still hold for
        #   an update to apply; nil writes unconditionally. Ignored for a delete
        # @return [Runtime::Instance, PG::Result, nil] a new instance with `version` set, nil on
        #   CAS mismatch, or the `DELETE` statement's `PG::Result`
        # @raise [PG::Error] if the statement fails
        def project(entry, expected_version: nil)
          advance_checkpoint!(entry.sequence) if entry.sequence
          return pg_exec_params("DELETE FROM #{quoted_table} WHERE id = $1", [entry.id]) if entry.delete?

          instance = Runtime::Instance.new(aggregate: @aggregate, id: entry.id, state: entry.state)
          stamp_version(instance, pg_exec_params(*upsert_statement(instance, expected_version)))
        end

        # Deletes every row of the aggregate's table and its journal; events, saga rows and
        # outbox rows are left in place.
        #
        # @return [Adapters::Postgres] self
        # @raise [PG::Error] if a statement fails
        def reset!
          pg_exec("DELETE FROM #{quoted_table}")
          pg_exec("DELETE FROM #{quoted_entry_table}")
          self
        end

        # Journals and upserts an instance's current state atomically.
        #
        # One transaction, so a crash between the journal insert and the row upsert
        # can never leave the two disagreeing.
        #
        # @param instance [Runtime::Instance] the instance to store
        # @return [Runtime::Instance] a new instance over the saved state, `version` set to the
        #   row's new `hecks_version`
        # @raise [PG::Error] if either statement fails; the transaction is rolled back
        def save(instance)
          entry = Ports::Persistence::Entry.new(operation: "save", id: instance.id.to_s, state: instance.state.dup)
          transaction do
            append(entry)
            project(entry)
          end
        end

        # Stores an entry under a per-identity advisory lock and reports whether it inserted,
        # replaced or conflicted, so two concurrent creators of one id cannot both insert.
        #
        # @param entry [Ports::Persistence::Entry] the save to store
        # @param insert_only [Boolean] when true, an existing row is left untouched
        # @return [Symbol] `:inserted`, `:replaced`, or `:conflicted` when `insert_only` met an
        #   existing row and nothing was written
        # @raise [PG::Error] if a statement fails; the transaction is rolled back
        def atomic_put(entry, insert_only: false)
          status = nil
          transaction { status = put_entry(entry, insert_only) }
          status
        end

        # Journals a delete and removes the row atomically, whether or not a row exists.
        #
        # @param id [String, Object] the aggregate identity, journalled as `id.to_s`
        # @return [Boolean] always true
        # @raise [PG::Error] if either statement fails; the transaction is rolled back
        def delete(id) # rubocop:disable Naming/PredicateMethod -- the repository port's verb, not a question
          entry = Ports::Persistence::Entry.new(operation: "delete", id: id.to_s, state: nil)
          transaction do
            append(entry)
            project(entry)
          end
          true
        end

        private

        # The instance with the version the upsert returned; nil when the CAS guard matched no row.
        def stamp_version(instance, result)
          return nil if result.ntuples.zero?

          instance.version = result[0]["hecks_version"].to_i
          instance
        end

        # `order_by` is a runtime value, so it is checked against the aggregate before use.
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

        # The upsert statement and its binds. `expected_version` adds the optimistic-concurrency
        # guard, so a stale writer's update matches no row.
        def upsert_statement(instance, expected_version)
          fields = persisted_fields
          values = [instance.id.to_s] + fields.map { |field| encode_field(field, instance[field[:name]]) } + [1]
          sql = upsert_sql(fields)
          return ["#{sql} RETURNING hecks_version", values] unless expected_version

          values += [expected_version]
          ["#{sql} WHERE #{quoted_table}.hecks_version = $#{values.size} RETURNING hecks_version", values]
        end

        def upsert_sql(fields)
          columns = ["id"] + fields.map { |field| field[:name].to_s } + ["hecks_version"]
          "INSERT INTO #{quoted_table} (#{columns.map { |c| quote_ident(c) }.join(", ")}) " \
            "VALUES (#{(1..columns.size).map { |n| "$#{n}" }.join(", ")}) " \
            "ON CONFLICT (id) DO UPDATE SET #{update_assignments(fields).join(", ")}"
        end

        def update_assignments(fields)
          fields.map { |field| "#{quote_ident(field[:name])} = EXCLUDED.#{quote_ident(field[:name])}" } +
            ["hecks_version = #{quoted_table}.hecks_version + 1"]
        end

        # Takes the per-identity advisory lock, then journals and projects unless an
        # `insert_only` put finds the row already there.
        def put_entry(entry, insert_only)
          pg_exec_params(
            "SELECT pg_advisory_xact_lock(" \
            "hashtext(current_schema() || ':' || $1), hashtext($2))",
            [table, entry.id.to_s]
          )
          exists = !pg_exec_params("SELECT 1 FROM #{quoted_table} WHERE id = $1", [entry.id.to_s]).ntuples.zero?
          return :conflicted if insert_only && exists

          append(entry)
          project(entry)
          exists ? :replaced : :inserted
        end

        # Stamps `.version` from `hecks_version` so a later CAS save has something
        # to check against.
        def instance_from_row(row)
          instance = Runtime::Instance.new(aggregate: @aggregate, id: row["id"], state: decode(row))
          instance.version = row["hecks_version"].to_i
          instance
        end
      end
    end
  end
end
