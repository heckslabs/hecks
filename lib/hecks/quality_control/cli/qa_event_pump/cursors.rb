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

        private

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
