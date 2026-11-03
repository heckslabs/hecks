# frozen_string_literal: true

module Hecks
  module QualityControlCli
    class QaEventPump
      # The positions the pump has read to, kept as the ledger's `EventCursor` rows: one per (log,
      # consumer). A row is opened at the start of the log the first time a consumer reads it.
      class Cursors
        # @param runtime [Hecks::Runtime::Dispatcher] the booted ledger the rows live in
        def initialize(runtime)
          @runtime = runtime
        end

        # @param log [String] the domain whose event log is read
        # @param consumer [String] the domain whose policies react
        # @return [Integer] the count of log entries the consumer has reacted to
        def position(log, consumer)
          row = row_for(key(log, consumer)) || open_row(log, consumer)
          row[:position][:value]
        end

        # Moves one consumer's cursor past the entries it has reacted to.
        #
        # @param log [String] the domain whose event log was read
        # @param consumer [String] the domain whose policies reacted
        # @param position [Integer] the count of entries now reacted to
        # @return [void]
        def advance(log, consumer, position)
          @runtime.dispatch_flat("QualityControl::EventCursor.Advance", to: key(log, consumer), position: position)
        end

        # Runs the block in one transaction on the ledger's store where that store has one, so a
        # reaction and the cursor past it commit together or not at all. A store without
        # transactions (Memory) yields, and the reaction log is then the only guard against a rerun.
        #
        # @yield the reaction and the cursor move, as one unit
        # @return [Object] the block's own value
        def transaction(&)
          repository = @runtime.registry.repository("QualityControl", cursor_aggregate)
          repository.respond_to?(:transaction) ? repository.transaction(&) : yield
        end

        private

        def cursor_aggregate = ledger_bluebook.aggregates.find { |aggregate| aggregate.hecks_name == "EventCursor" }

        def ledger_bluebook = @runtime.registry.bluebook("QualityControl")

        def key(log, consumer) = "#{log}/#{consumer}"

        def row_for(key) = @runtime.query("QualityControl::EventCursor.All").find { |row| row[:key][:value] == key }

        def open_row(log, consumer)
          @runtime.dispatch_flat("QualityControl::EventCursor.Start", key: key(log, consumer), log: log, consumer: consumer)
          row_for(key(log, consumer))
        end
      end
    end
  end
end
