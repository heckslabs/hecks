module Hecks
  module Adapters
    class Postgres
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
        # @raise [PG::Error] if the insert fails
        def append(entry)
          result = pg_exec_params(
            "INSERT INTO #{quoted_entry_table} (aggregate_id, operation, state, mirrors) VALUES ($1, $2, $3, $4) " \
            "RETURNING sequence",
            # `mirrors` is nullable; an absent hash must bind SQL NULL, not the
            # string "null", or a future IS NULL check would never match.
            [entry.id, entry.operation, state_json(entry.state), entry.mirrors && JSON.generate(entry.mirrors)]
          )
          entry.sequence = result[0]["sequence"].to_i
          entry
        end

        # Reads the whole journal back in append order, for `AppendOnly#recover!` to replay.
        #
        # @return [Array<Ports::Persistence::Entry>] every journalled entry, state decoded
        #   through the state codec and `mirrors` parsed with String keys (nil when none were
        #   stored); `[]` when nothing has been appended
        # @raise [PG::Error] if the statement fails
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
        # @raise [PG::Error] if the statement fails
        # @raise [JSON::ParserError] if a stored `state` or `mirrors` value is not valid JSON
        def entries_since(sequence)
          entries_matching(
            "SELECT aggregate_id, operation, state, mirrors, sequence FROM #{quoted_entry_table} " \
            "WHERE sequence > $1 ORDER BY sequence",
            [sequence]
          )
        end

        # Reads the highest journal `sequence` this table has already had projected into it.
        #
        # @return [Integer] `0` when the table has never been checkpointed (a fresh table, or one
        #   from before this bookkeeping existed) — `entries_since(0)` then reads the whole journal,
        #   matching `entries`' own full replay
        # @raise [PG::Error] if the statement fails
        def checkpoint
          result = pg_exec_params("SELECT last_sequence FROM hecks_checkpoints WHERE aggregate_table = $1", [table])
          result.ntuples.zero? ? 0 : result[0]["last_sequence"].to_i
        end

        # Reads the highest journal `sequence` compaction has already deleted from this table.
        #
        # @return [Integer] `0` when nothing has ever been compacted
        # @raise [PG::Error] if the statement fails
        def compacted_through
          result = pg_exec_params("SELECT compacted_through FROM hecks_checkpoints WHERE aggregate_table = $1", [table])
          result.ntuples.zero? ? 0 : result[0]["compacted_through"].to_i
        end

        # Deletes every journal row at or before `through` and records it, so a `:strict`
        # projection catch-up can tell whether it still has the history it needs.
        #
        # Never moves `compacted_through` backwards, and never touches the aggregate's own
        # table — only the journal, which a `:refresh` projection rebuild never needs.
        #
        # @param through [Integer] the highest `sequence` to delete
        # @return [Integer] the number of journal rows deleted
        # @raise [PG::Error] if a statement fails
        def compact_entries!(through:)
          removed = pg_exec_params("DELETE FROM #{quoted_entry_table} WHERE sequence <= $1", [through]).cmd_tuples
          pg_exec_params(
            "INSERT INTO hecks_checkpoints (aggregate_table, compacted_through) VALUES ($1, $2) " \
            "ON CONFLICT (aggregate_table) DO UPDATE SET " \
            "compacted_through = GREATEST(hecks_checkpoints.compacted_through, excluded.compacted_through)",
            [table, through]
          )
          removed
        end

        # Reads the chain heads the ledger sealed beside this journal, oldest first.
        #
        # @return [Array<Hash>] `through:` the highest sequence a seal covers, `head:` the chain
        #   digest at that point and `previous:` the head the seal followed (genesis digest first)
        # @raise [PG::Error] if a statement fails
        def ledger_anchors
          ensure_ledger_anchors!
          pg_exec_params(
            "SELECT through_sequence, head, previous FROM hecks_ledger_anchors " \
            "WHERE aggregate_table = $1 ORDER BY through_sequence", [table]
          ).map { |row| { through: row["through_sequence"].to_i, head: row["head"], previous: row["previous"] } }
        end

        # Seals a chain head beside this journal. Sealing the same point twice with the same head
        # changes nothing; a different head for a sealed point is refused, never overwritten.
        #
        # @param through [Integer] the highest journal sequence the head covers
        # @param head [String] the chain digest at `through`
        # @param previous [String] the head of the seal before this one
        # @return [void]
        # @raise [Runtime::WiringError] if the point is already sealed with another head
        # @raise [PG::Error] if a statement fails
        def record_ledger_anchor(through:, head:, previous:)
          ensure_ledger_anchors!
          sealed = ledger_anchors.find { |anchor| anchor[:through] == through }
          if sealed
            return if sealed[:head] == head

            raise Runtime::WiringError, "#{table} is already sealed through #{through} with another head: the journal changed"
          end

          pg_exec_params(
            "INSERT INTO hecks_ledger_anchors (aggregate_table, through_sequence, head, previous) " \
            "VALUES ($1, $2, $3, $4)", [table, through, head, previous]
          )
        end

        private

        def ensure_ledger_anchors!
          pg_exec_params(
            "CREATE TABLE IF NOT EXISTS hecks_ledger_anchors (" \
            "aggregate_table text NOT NULL, through_sequence bigint NOT NULL, head text NOT NULL, " \
            "previous text NOT NULL, sealed_at timestamptz NOT NULL DEFAULT now(), " \
            "PRIMARY KEY (aggregate_table, through_sequence))", []
          )
        end

        # Shared decode step for `entries`/`entries_since` — runs a query already selecting
        # `aggregate_id, operation, state, mirrors, sequence` and builds one Entry per row.
        def entries_matching(sql, binds = [])
          pg_exec_params(sql, binds).map do |row|
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
          pg_exec_params(
            "INSERT INTO hecks_checkpoints (aggregate_table, last_sequence) VALUES ($1, $2) " \
            "ON CONFLICT (aggregate_table) DO UPDATE SET " \
            "last_sequence = GREATEST(hecks_checkpoints.last_sequence, EXCLUDED.last_sequence)",
            [table, sequence]
          )
        end
      end
    end
  end
end
