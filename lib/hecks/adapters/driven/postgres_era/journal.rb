require "json"

module Hecks
  module Adapters
    class PostgresEra
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
        # @raise [Runtime::WiringError] if this boot's era has been superseded by a mint
        # @raise [PG::Error] if Postgres refuses a statement, such as the era fence's RLS
        def append(entry)
          refuse_superseded_write!
          transaction do
            lock_writes!
            append_and_project!(entry)
          end
          entry
        end

        # Refuses a write from a checkout whose era a later mint has superseded.
        # Runs before the transaction so a stale checkout takes no lock; reads stay allowed.
        #
        # @return [nil] when this boot's era is current
        # @raise [Runtime::WiringError] if the boot gate marked this era superseded
        def refuse_superseded_write!
          return unless @superseded_by

          raise Runtime::WiringError,
                "cannot write #{table} for #{@domain}: this checkout booted era #{@era}, which era " \
                "#{@superseded_by} has superseded — its shape was replaced by a mint, and a write here would " \
                "land in a partition no newer head reads. Reads still work; pull the current bluebook and " \
                "reboot to write again."
        end

        # Saves an entry and reports whether it inserted or replaced, decided under the same lock
        # that guards the write.
        #
        # @param entry [Ports::Persistence::Entry] the save to journal
        # @param insert_only [Boolean] when true, an id already in the head is left untouched
        # @return [Symbol] `:inserted`, `:replaced`, or `:conflicted` when `insert_only` hit a
        #   record
        # @raise [Runtime::WiringError] if this boot's era has been superseded by a mint
        # @raise [PG::Error] if Postgres refuses a statement
        def atomic_put(entry, insert_only: false)
          refuse_superseded_write!
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
        # @return [Adapters::PostgresEra] this adapter
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
