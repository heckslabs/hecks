# frozen_string_literal: true

require_relative "../rules"
require_relative "readings"
require_relative "daily_health"

module Hecks
  module Adapters
    module PipelineBoard
      # The cycles, the day's health and the integration runs as the rows the bluebook declares
      # for them: `Cycle`, `IntegrationRun`, and a `Reading` for each stage's statistics and each
      # health check. It reshapes what the builders answered and reads nothing.
      module TypedRows
        module_function

        # @param found [Array<Hash>] the cycles as {Cycles.build} laid them
        # @return [Array<Hash>] one `Cycle` row each, its stages as words
        def cycles(found)
          found.map do |cycle|
            { work: cycle[:work].to_s, started: cycle[:started].to_s, seconds: cycle[:seconds].to_i,
              open: cycle[:open].to_s, stages: spans(cycle[:stages]) }
          end
        end

        # @return [String] each stage with its seconds, in order: `queue 120s, review 40s (open)`
        def spans(measured)
          measured.map { |entry| "#{entry[:stage]} #{entry[:seconds]}s#{" (open)" if entry[:open]}" }.join(", ")
        end

        # @param reading [Hash] `stats` and `rank` as {Cycles.build} answered them
        # @param at [String] when the events were read
        # @return [Array<Hash>] one `Reading` per stage: its median seconds
        def cycle_stats(reading, at)
          reading[:stats].map do |row|
            note = "p#{reading[:rank]} #{row[:percentile] || "-"}s over #{row[:items]} items"
            { key: "cycle_#{row[:stage]}", label: "#{row[:stage]} stage", value: row[:median].to_s, unit: "s",
              state: Rules.verdict("Read", { value: row[:median] }), note: note }.merge(Readings.read("cycle", at))
          end
        end

        # @param report [Hash] the day's findings by check, as {DailyHealth.build} answered them
        # @param at [String] when they were read
        # @return [Array<Hash>] one `Reading` per `HealthCheck` row: how many it found
        def health(report, at)
          Rules.rows("HealthCheck").map { |row| check(row, report[row[:kind].to_sym], at) }
        end

        # @return [Hash] one check's `Reading`; a check that could not be read is `unknown`
        def check(row, found, at)
          count = found.is_a?(Array) ? found.size : nil
          { key: row[:kind], label: row[:says], value: count.to_s, unit: "",
            state: Rules.verdict("Pipeline health", { found: count }), note: found_note(found) }
            .merge(Readings.read("health", at))
        end

        # @return [String] each finding's key and age, or why the check could not be read
        def found_note(found)
          return "unknown: #{found.is_a?(Hash) ? found[:unknown] : "nothing read"}" unless found.is_a?(Array)

          found.map { |entry| DailyHealth.brief(entry) }.join(" ")
        end

        # @param runs [Array<Hash>] the runs as {IntegrationRuns.build} listed them
        # @return [Array<Hash>] one `IntegrationRun` row each
        def integration(runs)
          runs.map do |run|
            { landed: run[:landed].to_s, stage: run[:stage].to_s, at: run[:at].to_s, minutes: run[:minutes].to_i,
              parked: run[:parked] ? "yes" : "" }
          end
        end
      end
    end
  end
end
