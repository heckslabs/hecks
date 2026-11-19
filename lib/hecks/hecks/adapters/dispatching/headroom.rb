# frozen_string_literal: true

require_relative "../started_work"

module Hecks
  module Adapters
    class Dispatching
      # How many more sessions the machine has room for, estimated from its recent load readings.
      #
      # The idle load is the quiet quarter of the readings; each started session is taken to cost
      # what the recent median stands over it, divided among them. The estimate also counts load
      # that is not a session's, so a fill's report states it and no work item is held to it: the
      # load limit alone stops a fill.
      class Headroom
        # Readings the estimate looks at.
        WINDOW = 48

        # Load one session costs when the readings cannot say, measured on 2026-11-14.
        DEFAULT_PER_SESSION = 1.6

        # @param registry [Runtime::Registry, nil] the booted registry holding the Machine readings
        # @param count [Integer] how many of the newest readings
        # @return [Array<Float>] their loads, oldest first; empty when none is recorded
        def self.loads(registry, count: WINDOW)
          aggregate = machine(registry)
          return [] unless aggregate

          readings = registry.repository("Hecks", aggregate).all.to_a
          readings.last(count).filter_map { |record| StartedWork.value(record, :load)&.to_f }
        end

        # @param registry [Runtime::Registry, nil]
        # @return [Object, nil] the Machine aggregate, nil when no Hecks bluebook is booted
        def self.machine(registry)
          bluebook = registry&.bluebook("Hecks")
          bluebook&.aggregates&.find { |held| held.hecks_name == "Machine" }
        end

        # @param loads [Array<Float>] recent 1-minute loads, oldest first
        # @param started [Integer] the sessions running now
        # @param load [Float] the load now
        # @param max_load [Float] the load above which no session starts
        def initialize(loads:, started:, load:, max_load:)
          @loads = loads
          @started = started
          @load = load
          @max_load = max_load
        end

        # @return [Float] the load one session costs, estimated: the default with too few readings,
        #   fewer than two sessions, or a load not above the idle one
        def per_session
          return DEFAULT_PER_SESSION if @loads.empty? || @started < 2

          extra = median - idle
          extra.positive? ? extra / @started : DEFAULT_PER_SESSION
        end

        # @return [Integer, nil] the sessions the load has room for, 0 at the limit; nil when there
        #   are no readings, so the cap and the load limit alone apply
        def room
          return if @loads.empty?

          [((@max_load - @load) / per_session).floor, 0].max
        end

        private

        def idle = @loads.sort[@loads.size / 4]

        def median = @loads.sort[@loads.size / 2]
      end
    end
  end
end
