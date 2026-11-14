# frozen_string_literal: true

module Hecks
  module Adapters
    class Standup
      # One reading of the machine in words: the load average against the most Dispatch allows,
      # then the CPU and the memory, each to two decimal places. A gauge the machine does not give
      # is left out.
      class Gauges
        # Each memory or CPU gauge with the words that say it.
        WORDS = { cpu_idle: "CPU %s%% idle", swap_used: "swap %s%% used", compressor_gb: "compressor %s GB",
                  free_gb: "%s GB free" }.freeze

        # @param gauges [Hash{Symbol => Float, nil}] what {MachineSampling::Readings} answered
        # @param max_load [Float] the load average above which Dispatch starts nothing
        def initialize(gauges, max_load)
          @gauges = gauges
          @max_load = max_load
        end

        # @return [String] the gauges the machine gave, in one line
        def line
          said = WORDS.filter_map { |gauge, words| format(words, @gauges[gauge].round(2)) if @gauges[gauge] }
          ([load] + said).compact.join(", ")
        end

        private

        def load = @gauges[:load] && "load #{@gauges[:load]} of #{@max_load} allowed"
      end
    end
  end
end
