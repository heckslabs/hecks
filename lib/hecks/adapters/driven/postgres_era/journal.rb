require "json"

module Hecks
  module Adapters
    class PostgresRevision
      # Writing and reading the journal: every append, with the head snapshot and field caches
      # it keeps current in the same transaction, and the reads of the whole journal.
      module Journal
        # Appends one entry to the journal and updates the head snapshot and every field cache,
        # all in one transaction under the domain's write lock.
        #
        # The lock precedes the INSERT because the ordinal comes from `nextval()` inside it. It is
        # a different key from `mint_era!`'s, so it serializes writes, never a write against a mint.
        # `project` stays out of it: AppendOnly#recover! already replays it on every boot.
        #
        # @param entry [Ports::Persistence::Entry] the save or delete to journal
        # @return [Ports::Persistence::Entry] the same entry, unchanged
        # @raise [Runtime::WiringError] if this boot's shape is not minted yet, or its era has been
        #   superseded by a mint
        # @raise [PG::Error] if Postgres refuses a statement, such as the era fence's RLS
        def append(entry)
          refuse_unwritable_boot!(entry)
          transaction do
            lock_writes!
            append_and_project!(entry)
          end
          entry
        end

        # Refuses a write from a checkout whose shape no era holds yet, or whose era a later mint
        # has superseded. Runs before the transaction so a stale checkout takes no lock; reads stay
        # allowed. An unminted boot lets through the one entry whose command declared `mints_era
        # true`; a superseded boot refuses that entry too.
        #
        # @param entry [Ports::Persistence::Entry] the write about to be journaled
        # @return [nil] when this boot's era is current
        # @raise [Runtime::WiringError] if the boot gate left this shape unminted and the entry is
        #   not a mint command's record, or marked its era superseded
        def refuse_unwritable_boot!(entry)
          raise Runtime::WiringError, unminted_refusal if @unminted && !entry.mints_era?
          return unless @superseded_by

          raise Runtime::WiringError, superseded_refusal
        end

        # Saves an entry and reports whether it inserted or replaced, decided under the same lock
        # that guards the write.
        #
        # @param entry [Ports::Persistence::Entry] the save to journal
        # @param insert_only [Boolean] when true, an id already in the head is left untouched
        # @return [Symbol] `:inserted`, `:replaced`, or `:conflicted` when `insert_only` hit a
        #   record
        # @raise [Runtime::WiringError] if this boot's shape is not minted yet, or its era has been
        #   superseded by a mint
        # @raise [PG::Error] if Postgres refuses a statement
        def atomic_put(entry, insert_only: false)
          refuse_unwritable_boot!(entry)
          status = nil
          transaction do
            lock_writes!
            status = put_status(head_row?(entry.id), insert_only)
            append_and_project!(entry) unless status == :conflicted
          end
          status
        end

        # Reads this aggregate's whole journal, every era, in write order. States are decoded but
        # not translated: an ancestor era's row keeps the shape it was written in.
        #
        # @return [Array<Ports::Persistence::Entry>] entries by ascending ordinal
        def entries
          @db.exec_params(
            "SELECT aggregate_id, operation, state, mirrors FROM #{@lineage.quoted_journal} " \
            "WHERE aggregate = $1 ORDER BY ordinal",
            [table]
          ).map { |row| entry_from_row(row) }
        end

        # Deletes this aggregate's journal rows, refusing when row-level security turns the DELETE
        # into a silent no-op.
        #
        # The journal forces RLS with no DELETE policy, so an ordinary connection matches zero rows
        # without error; comparing the count before with the DELETE's own count exposes that.
        # Head snapshots, field caches, `events` and saga rows are left as they are.
        #
        # @return [Adapters::PostgresRevision] this adapter
        # @raise [Runtime::WiringError] if the journal held rows and the DELETE removed none
        def reset!
          before = @db.exec_params(
            "SELECT count(*) FROM #{@lineage.quoted_journal} WHERE aggregate = $1", [table]
          )[0]["count"].to_i
          result = @db.exec_params("DELETE FROM #{@lineage.quoted_journal} WHERE aggregate = $1", [table])
          refuse_silent_delete!(before, result)
          self
        end

        private

        def unminted_refusal
          "cannot write #{table} for #{@domain}: the shape is not minted yet; run the mint entry point. " \
            "This checkout's shape#{compared_labels} is held by no era, and a write here would land in era " \
            "#{@era}, the latest held era, under a shape it does not hold. Reads still work."
        end

        # The two labels the boot compared, as far as each can be read: the held era's and this
        # checkout's. Empty when neither can.
        def compared_labels
          held = held_label
          current = current_label
          return "" unless held || current

          " (#{current || "unknown"}, against held era #{@era}'s #{held || "unknown"})"
        end

        # @return [String, nil] the label of the era this boot reads, or nil when it cannot be read
        def held_label
          @lineage.eras.find { |era| era[:ordinal] == @era }&.fetch(:label, nil)
        rescue *unreadable_lineage_errors
          nil
        end

        # The errors that mean a lineage cannot be read. PG::Error is named only when the pg gem
        # is loaded: a shard that never loads it must not raise NameError from the rescue itself.
        def unreadable_lineage_errors
          defined?(PG::Error) ? [PG::Error, Runtime::WiringError] : [Runtime::WiringError]
        end

        # @return [String, nil] this checkout's shape label, or nil for an aggregate with no owner
        def current_label
          owner = @aggregate.hecks_owner
          owner && Runtime::StorageShape.mint_label(owner)
        end

        def superseded_refusal
          "cannot write #{table} for #{@domain}: this checkout booted era #{@era}, which era " \
            "#{@superseded_by} has superseded — its shape was replaced by a mint, and a write here would " \
            "land in a partition no newer head reads. Reads still work; pull the current bluebook and " \
            "reboot to write again."
        end

        def head_row?(id)
          !@db.exec_params("SELECT 1 FROM #{quoted_head} WHERE id = $1 LIMIT 1", [id.to_s]).ntuples.zero?
        end

        def put_status(exists, insert_only)
          return :conflicted if insert_only && exists

          exists ? :replaced : :inserted
        end

        def entry_from_row(row)
          state = row["state"] && JSON.parse(row["state"])
          Ports::Persistence::Entry.new(
            operation: row["operation"] || "save",
            id:        row["aggregate_id"],
            state:     Ports::Persistence::StateCodec.decode(@aggregate, state),
            mirrors:   row["mirrors"] && JSON.parse(row["mirrors"])
          )
        end

        def refuse_silent_delete!(before, result)
          return unless before.positive? && result.cmd_tuples.zero?

          raise Runtime::WiringError,
                "reset! deleted 0 of #{before} row(s) for #{table} in #{@lineage.quoted_journal} — " \
                "FORCE ROW LEVEL SECURITY admits no DELETE policy on the journal, so this connection's " \
                "DELETE silently matched nothing. reset! only works connected as an actual Postgres " \
                "superuser or a role granted BYPASSRLS, not as the provisioner or an app role."
        end
      end
    end
  end
end
