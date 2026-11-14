# frozen_string_literal: true

require_relative "console_capture"
require_relative "ledger_keeping/ledger"

module Hecks
  module Adapters
    # The `Weighing` port's adapter for `LedgerCare`: on a beat, counts the AgentRun journal
    # entries a compaction would delete and says the journal is due when they pass the Tickets
    # world's `ledger_care` line. It takes the file's write lock for the world's few seconds to
    # count, so a file another process holds is deferred by name and the next beat looks again;
    # it never waits longer and never retries. It compacts nothing: `SchemaRevision.Compact` does,
    # once the bluebook hears the journal is due.
    class LedgerWeighing
      # @param registry [Runtime::Registry, nil] the booted registry whose world and records are
      #   read
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] unused
      # @param root [String, nil] unused
      def initialize(registry: nil, aggregate: nil, settings: {}, root: nil)
        @registry = registry
      end

      # @param held [Hash] the `LedgerCare` record: `run`
      # @return [Hash{Symbol => Hash}] `domain`, `aggregates` and `compaction` for the request,
      #   and `reason`
      # @raise [ConsoleCapture::Failure] naming why the journal is left for the next beat
      def weigh(**held)
        database = LedgerKeeping::Ledger.database(@registry) or
          raise ConsoleCapture::Failure, "deferred: the AgentRun records are not kept in a SQLite file"
        due(database.compactable, plain(held[:run]))
      rescue LedgerKeeping::Held => e
        raise ConsoleCapture::Failure,
              "deferred: #{File.basename(database.path)} is held by another process (#{e.message}); " \
              "the next beat tries again"
      end

      private

      def due(entries, run)
        line = LedgerKeeping::Ledger.setting(@registry, :entries)
        raise ConsoleCapture::Failure, "deferred: #{entries} entries are compactable, not over #{line}" if entries <= line

        { domain: { value: @registry.root.to_s }, aggregates: { value: LedgerKeeping::Ledger::AGGREGATE },
          compaction: { value: "ledger-care-#{run}" },
          reason: { value: "#{entries} journal entries are compactable, over #{line}" } }
      end

      def plain(argument) = argument.is_a?(Hash) ? argument[:value] : argument
    end
  end
end
