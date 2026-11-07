require_relative "stats"

module Hecks
  module Bench
    # Reduces one target's run summaries on one workload to the median figures a report prints.
    module Aggregate
      # The figures taken as a median across runs (`:boot_us` only a kernel client reports).
      MEDIAN_KEYS = %i[throughput_per_s p50_us p99_us mean_us max_us drift boot_us].freeze

      module_function

      # @param domain [String] the workload's name
      # @param target [String] the runtime measured
      # @param summaries [Array<Hash>] `Run#summary` of each fresh boot
      # @return [Hash] the runs, their medians and the range of throughput
      def call(domain, target, summaries)
        rates = summaries.map { |summary| summary[:throughput_per_s] }
        median = MEDIAN_KEYS.to_h { |key| [key, Stats.median(summaries.filter_map { |s| s[key] })] }
        median[:roundtrip_floor_p50_us] = Stats.median(summaries.filter_map { |s| s[:roundtrip_floor_p50_us] })
        median[:by_verb] = median_by_verb(summaries)
        { domain: domain, target: target, runs: summaries, median: median.compact, throughput_range: rates.minmax }
      end

      def median_by_verb(summaries)
        summaries.first[:by_verb].keys.to_h do |verb|
          [verb, %i[p50_us p99_us].to_h { |key| [key, Stats.median(summaries.map { |s| s[:by_verb][verb][key] })] }]
        end
      end
    end
  end
end
