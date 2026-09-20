module Hecks
  module Adapters
    class Sqlite
      # The write path: journal `append`, snapshot `project`, `entries`
      # replay, `reset!`, and the two save entry points (`save`,
      # `atomic_put`) — split out of the `Sqlite` class body only to keep
      # it under its line budget; every method here stays public/private
      # on `Sqlite` instances exactly as if it were still defined there.
      module Writes
        # Inserts one journal row, outside any transaction of its own.
        #
        # @param entry [Ports::Persistence::Entry] the save or delete to journal; `state` is
        #   encoded through the state codec and `mirrors` stored as JSON, or NULL when nil
        # @return [Ports::Persistence::Entry] the same `entry`
        # @raise [SQLite3::Exception] if the insert fails
        def append(entry)
          @db.execute(
            "INSERT INTO #{quoted_entry_table} (aggregate_id, operation, state, mirrors) VALUES (?, ?, ?, ?)",
            # `mirrors` (unlike `state`) is a nullable column — an absent
            # mirrors hash must bind a real SQL NULL, not the four-character
            # JSON text `"null"` (`JSON.generate(nil)`), or a future `IS NULL`
            # check against it would never match. Same guard `postgres_era.rb`
            # already uses for its own journal's `mirrors` column.
            [entry.id, entry.operation, JSON.generate(Ports::Persistence::StateCodec.encode(@aggregate, entry.state)),
             entry.mirrors && JSON.generate(entry.mirrors)]
          )
          entry
        end

        # Replaces or deletes the aggregate's row for one journal entry.
        #
        # @param entry [Ports::Persistence::Entry] the save or delete to materialize
        # @return [Runtime::Instance, Array] for a save, a new instance over the entry's state;
        #   for a delete, the `DELETE` statement's empty result rows
        # @raise [SQLite3::Exception] if the statement fails
        def project(entry)
          return @db.execute("DELETE FROM #{quoted_table} WHERE id = ?", [entry.id]) if entry.delete?

          instance = Runtime::Instance.new(aggregate: @aggregate, id: entry.id, state: entry.state)
          insert_or_replace_row(instance)
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
          @db.execute("SELECT aggregate_id, operation, state, mirrors FROM #{quoted_entry_table} ORDER BY sequence").map do |row|
            state = JSON.parse(row["state"])
            Ports::Persistence::Entry.new(
              operation: row["operation"] || "save",
              id:        row["aggregate_id"],
              state:     Ports::Persistence::StateCodec.decode(@aggregate, state),
              mirrors:   row["mirrors"] && JSON.parse(row["mirrors"])
            )
          end
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
        # The outcome lookup, journal append and snapshot replacement share one
        # SQLite transaction. The runtime performs no preliminary find; this
        # adapter-native operation owns both concurrency and outcome reporting.
        #
        # @param entry [Ports::Persistence::Entry] the save to store
        # @param insert_only [Boolean] when true, an existing row is left untouched
        # @return [Symbol] `:inserted`, `:replaced`, or `:conflicted` when `insert_only` met an
        #   existing row and nothing was written
        # @raise [SQLite3::Exception] if a statement fails; the transaction is rolled back
        def atomic_put(entry, insert_only: false)
          status = nil
          transaction { status = atomic_put_transaction(entry, insert_only) }
          status
        end

        private

        def insert_or_replace_row(instance)
          columns = instance_columns
          slots   = Array.new(columns.size, "?").join(", ")
          @db.execute("INSERT OR REPLACE INTO #{quoted_table} (#{columns.join(', ')}) VALUES (#{slots})",
                      instance_values(instance))
        end

        def instance_columns
          (["id"] + persisted_fields.map { |field| field[:name].to_s }).map { |c| quote_ident(c) }
        end

        def instance_values(instance)
          [instance.id.to_s] + persisted_fields.map { |field| encode_field(field, instance[field[:name]]) }
        end

        def atomic_put_transaction(entry, insert_only)
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
