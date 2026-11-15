# frozen_string_literal: true

require "time"

module Hecks
  module Adapters
    module LedgerKeeping
      # Deletes the delivered rows of the AgentRun file's `hecks_outbox`, oldest settled first, in
      # batches that each take the write lock and let it go, so a large backlog never holds the
      # writer for long and a beat that stops at its cap leaves the rest to the next beat.
      #
      # The delete covers every aggregate whose outbox shares the file: a delivered row is settled
      # whichever aggregate wrote it. Pending, claimed, failed and refused rows are never touched.
      class OutboxPurge
        # Rows deleted per transaction.
        BATCH = 10_000

        # Batches a beat runs at most, so one beat deletes at most `BATCH * BATCHES` rows.
        BATCHES = 20

        # @param database [Database] the AgentRun file
        def initialize(database)
          @database = database
        end

        # @param hours [Numeric] how long a delivered row is kept
        # @return [Integer] how many rows were deleted
        # @raise [Held] when the write lock is not taken within the wait
        def purge!(hours:)
          cutoff = (Time.now.utc - (hours * 3600)).iso8601
          total = 0
          BATCHES.times do
            deleted = delete_batch(cutoff)
            total += deleted
            break if deleted < BATCH
          end
          total
        end

        private

        def delete_batch(cutoff)
          @database.writing do |db|
            next 0 unless db.get_first_value("SELECT 1 FROM sqlite_master WHERE name = 'hecks_outbox'")

            db.execute(
              "DELETE FROM hecks_outbox WHERE id IN (SELECT id FROM hecks_outbox " \
              "WHERE status = 'delivered' AND settled_at < ? LIMIT #{BATCH})", [cutoff]
            )
            db.changes.tap { db.execute("COMMIT TRANSACTION") }
          end
        end
      end
    end
  end
end
