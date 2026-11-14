# frozen_string_literal: true

require_relative "console_capture"
require_relative "ledger_keeping/ledger"

module Hecks
  module Adapters
    # The `Reclaiming` port's adapter for `LedgerFile`: a vacuum of the AgentRun file, which gives
    # back the pages compaction freed. A vacuum holds the whole file, so the file counts as quiet
    # only when its exclusive lock is taken within the Tickets world's `ledger_care` wait, which no
    # other open transaction allows; otherwise it is refused by name and the file is left as it was.
    class LedgerReclaiming
      # @param registry [Runtime::Registry, nil] the booted registry whose records are read
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] unused
      # @param root [String, nil] unused
      def initialize(registry: nil, aggregate: nil, settings: {}, root: nil)
        @registry = registry
      end

      # @param _held [Hash] the `LedgerFile` record: `run`, which the vacuum does not read
      # @return [Hash{Symbol => Hash}] `report`, the file's size before and after
      # @raise [ConsoleCapture::Failure] naming why the file was not vacuumed
      def vacuum(**)
        database = LedgerKeeping::Ledger.database(@registry) or
          raise ConsoleCapture::Failure, "refused: the AgentRun records are not kept in a SQLite file"
        { report: { value: report(database, database.vacuum!) } }
      rescue LedgerKeeping::Held => e
        raise ConsoleCapture::Failure,
              "refused: #{File.basename(database.path)} is not quiet, its lock was not taken within " \
              "#{LedgerKeeping::Ledger.setting(@registry, :wait_seconds)} seconds (#{e.message}); " \
              "nothing was changed"
      end

      private

      def report(database, sizes)
        "vacuumed #{File.basename(database.path)}: #{sizes[:before]} bytes before, #{sizes[:after]} bytes after"
      end
    end
  end
end
