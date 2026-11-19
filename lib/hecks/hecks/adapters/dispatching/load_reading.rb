# frozen_string_literal: true

module Hecks
  module Adapters
    class Dispatching
      # What a fill's report says of the load it compared with its limit: where the figure came
      # from, when it was read, and the sampler's own newest reading beside it.
      #
      # The limit is held to the figure the fill read itself, from `uptime` or, with the Tickets
      # world's `metering.roundhouse` switch on, from Roundhouse's meter. The sampler's reading
      # carries no time, so it is stated and compared, never substituted: a sampler that has
      # stopped must not clear a loaded machine.
      class LoadReading
        # How far apart the two figures may stand before the report says they disagree.
        DISAGREEMENT = 2.0

        # @param load [Float] the 1-minute load the fill read
        # @param sampled [Float, nil] the newest load the sampler recorded; nil when none
        # @param at [String] the time the fill read, as the report states it
        # @param source [String] where the fill read its load: `uptime` or `roundhouse`
        def initialize(load:, sampled:, at:, source: "uptime")
          @load = load
          @sampled = sampled
          @at = at
          @source = source
        end

        # @return [String] the header clause, such as
        #   `load source: uptime 9.0 at 14:12:27Z; sampler 4.6 differs by 4.4 (over 2.0)`
        def clause
          "load source: #{@source} #{@load.round(1)} at #{@at}; #{sampler_clause}"
        end

        # @return [Boolean] whether the sampler's reading stands over `DISAGREEMENT` from the load
        #   the fill read
        def disagree?
          !@sampled.nil? && (@load - @sampled).abs > DISAGREEMENT
        end

        private

        def sampler_clause
          return "sampler reading none recorded" unless @sampled

          gap = (@load - @sampled).abs.round(1)
          disagree? ? "sampler #{@sampled.round(1)} differs by #{gap} (over #{DISAGREEMENT})" : "sampler #{@sampled.round(1)}"
        end
      end
    end
  end
end
