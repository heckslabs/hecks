# frozen_string_literal: true

module Hecks
  module Adapters
    class Dispatching
      # What a fill's report says of the load it compared with its limit: where the figure came
      # from, when it was read, and the sampler's own newest reading beside it.
      #
      # The limit is held to the `uptime` figure the fill read. The sampler's reading carries no
      # time, so it is stated and compared, never substituted: a sampler that has stopped must not
      # clear a loaded machine.
      class LoadReading
        # How far apart the two figures may stand before the report says they disagree.
        DISAGREEMENT = 2.0

        # @param uptime [Float] the 1-minute load the fill read from `uptime`
        # @param sampled [Float, nil] the newest load the sampler recorded; nil when none is recorded
        # @param at [String] the time the fill read, as the report states it
        def initialize(uptime:, sampled:, at:)
          @uptime = uptime
          @sampled = sampled
          @at = at
        end

        # @return [String] the header clause, such as
        #   `load source: uptime 9.0 at 14:12:27Z; sampler 4.6 differs by 4.4 (over 2.0)`
        def clause
          "load source: uptime #{@uptime.round(1)} at #{@at}; #{sampler_clause}"
        end

        # @return [Boolean] whether the sampler's reading stands over {DISAGREEMENT} from `uptime`
        def disagree?
          !@sampled.nil? && (@uptime - @sampled).abs > DISAGREEMENT
        end

        private

        def sampler_clause
          return "sampler reading none recorded" unless @sampled

          gap = (@uptime - @sampled).abs.round(1)
          disagree? ? "sampler #{@sampled.round(1)} differs by #{gap} (over #{DISAGREEMENT})" : "sampler #{@sampled.round(1)}"
        end
      end
    end
  end
end
