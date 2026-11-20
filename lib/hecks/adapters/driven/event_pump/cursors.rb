# frozen_string_literal: true

module Hecks
  module Adapters
    class EventPump
      # The positions the pump has read to, kept as `EventDelivery::Consumer` rows: one per (log,
      # consumer). A row is started at the start of the log the first time a consumer reads it.
      class Cursors
        # @param runtime [Hecks::Runtime::Dispatcher] the booted ledger that attaches EventDelivery
        def initialize(runtime)
          @runtime = runtime
        end

        # @param log [String] the domain whose event log is read
        # @param consumer [String] the domain whose policies react
        # @return [Integer] the count of log entries the consumer has reacted to
        def position(log, consumer)
          row = row_for(key(log, consumer)) || start(log, consumer)
          row[:position][:value]
        end

        # Moves one consumer's cursor past the entries it has reacted to. The command's own `to`
        # is the position, so the receiver goes by the nested form, not the flat one.
        #
        # @param log [String] the domain whose event log was read
        # @param consumer [String] the domain whose policies reacted
        # @param position [Integer] the count of entries now reacted to
        # @return [void]
        def advance(log, consumer, position)
          @runtime.dispatch("EventDelivery::Consumer.Advance", to: key(log, consumer), with: { to: position })
        end

        # Runs the block in one transaction on the consumers' store where that store has one, so a
        # reaction and the cursor past it commit together or not at all. A store without
        # transactions (Memory) yields, and the reaction log is then the only guard against a rerun.
        #
        # @yield the reaction and the cursor move, as one unit
        # @return [Object] the block's own value
        def transaction(&)
          repository = @runtime.registry.repository("EventDelivery", consumer_aggregate)
          repository.respond_to?(:transaction) ? repository.transaction(&) : yield
        end

        private

        def consumer_aggregate = delivery_aggregates.find { |aggregate| aggregate.hecks_name == "Consumer" }

        def delivery_aggregates = @runtime.registry.bluebook("EventDelivery").aggregates

        def key(log, consumer) = "#{log}/#{consumer}"

        def row_for(key) = @runtime.query("EventDelivery::Consumer.All").find { |row| row[:key][:value] == key }

        def start(log, consumer)
          @runtime.dispatch_flat("EventDelivery::Consumer.Start", key: key(log, consumer), log: log, consumer: consumer)
          row_for(key(log, consumer))
        end
      end
    end
  end
end
