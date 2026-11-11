# frozen_string_literal: true

module Hecks
  module Adapters
    # Says whether the `Ticker` aggregate of a booted registry is kept in a store other than
    # Memory. Each tick of a chain is a launcher call of its own, in another process, and finds its
    # record there; in Memory that process holds none, so a chain would end at its first tick.
    class TickerPersistence
      # The aggregate whose store is read.
      AGGREGATE = "Ticker"

      # @param registry [Runtime::Registry, nil] the booted registry; nil answers persisted, as
      #   there is nothing to read
      def initialize(registry)
        @registry = registry
      end

      # @return [Boolean] whether the Ticker's store outlives the process
      def persisted?
        return true unless @registry

        adapter && adapter != ::Hecks::Ports::Persistence::DEFAULT_ADAPTER
      end

      # @return [String] why a chain cannot start when the Ticker is not persisted
      def refusal
        "the Ticker is in #{adapter || "no store"}, so a tick in its own process would find no record: " \
          "persist Hecks::Ticker in this checkout's hecks.local.hecksagon (the push train's copy included)"
      end

      private

      def adapter
        @adapter ||= begin
          name, bluebook = @registry.bluebooks.find { |_, book| book.aggregates.any? { |a| a.name == AGGREGATE } }
          name && ::Hecks::Ports::Persistence::BindingPolicy.resolve(@registry, name, ticker_in(bluebook)).adapter
        end
      end

      def ticker_in(bluebook) = bluebook.aggregates.find { |aggregate| aggregate.name == AGGREGATE }
    end
  end
end
