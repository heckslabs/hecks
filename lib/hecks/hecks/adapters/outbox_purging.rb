# frozen_string_literal: true

require_relative "console_capture"
require_relative "ledger_keeping/ledger"
require_relative "ledger_keeping/outbox_purge"

module Hecks
  module Adapters
    # The `Purging` port's adapter for `OutboxCare`: on a beat, deletes the delivered outbox rows of
    # the AgentRun file that were settled before the Tickets world's `ledger_care` `outbox_hours`.
    # It deletes in batches and answers how many went; with none to delete, or the file held past
    # the world's wait, the beat is deferred by name and the next one looks again. It never
    # vacuums: `LedgerFile.Reclaim` does, once the bluebook hears rows were purged.
    class OutboxPurging
      # @param registry [Runtime::Registry, nil] the booted registry whose world and records are
      #   read
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] unused
      # @param root [String, nil] unused
      def initialize(registry: nil, aggregate: nil, settings: {}, root: nil)
        @registry = registry
      end

      # @param held [Hash] the `OutboxCare` record: `run`
      # @return [Hash{Symbol => Hash}] `reason` and the `reclaim` key for the vacuum it asks for
      # @raise [ConsoleCapture::Failure] naming why the outbox is left for the next beat
      def purge(**held)
        database = LedgerKeeping::Ledger.database(@registry) or
          raise ConsoleCapture::Failure, "deferred: the AgentRun records are not kept in a SQLite file"
        purged(database, plain(held[:run]))
      rescue LedgerKeeping::Held => e
        raise ConsoleCapture::Failure,
              "deferred: #{File.basename(database.path)} is held by another process (#{e.message}); " \
              "the next beat tries again"
      end

      private

      def purged(database, run)
        hours = LedgerKeeping::Ledger.setting(@registry, :outbox_hours)
        count = LedgerKeeping::OutboxPurge.new(database).purge!(hours: hours)
        raise ConsoleCapture::Failure, "deferred: no delivered outbox rows are older than #{hours} hours" if count.zero?

        { reason:  { value: "#{count} delivered outbox rows older than #{hours} hours were purged" },
          reclaim: { value: "outbox-care-#{run}" } }
      end

      def plain(argument) = argument.is_a?(Hash) ? argument[:value] : argument
    end
  end
end
