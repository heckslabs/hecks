module Hecks
  module Adapters
    class Sqlite
      # The append-only entry table and its checkpoint bookkeeping.
      module Journal
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
      end
    end
  end
end
