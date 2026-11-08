# frozen_string_literal: true

require_relative "tile_kit"
require_relative "../rules"
require_relative "red_reading"

module Hecks
  module Adapters
    module PipelineBoard
      # The tiles that read CI: success rate, wall time against the goal, failed jobs on the head,
      # how long main has been red, and how long a commit takes to get a green CI.
      module CiTiles
        include TileKit

        # The settings the CI tiles read. The bluebook's `Setting` rows give their defaults, and the
        # QualityControl world's `ci_health` line overrides them.
        HEALTH_KEYS = %i[wall_goal_minutes success_good success_fair].freeze

        # @return [Hash{Symbol => Integer}] the defaults the bluebook declares
        def self.defaults = Rules.settings(*HEALTH_KEYS)

        # @param registry [Runtime::Registry, nil]
        # @return [Hash{Symbol => Integer}] the wall goal (minutes) and the success bands (percent)
        def self.health(registry)
          declared = registry&.world("QualityControl")&.for_verb("ci_health") || {}
          defaults.merge(declared.slice(*HEALTH_KEYS)).transform_values { |v| Integer(v) }
        end

        # @param runs [Array<Hash>] CI runs, oldest first
        def success(runs, health)
          spec = { id: "success", label: "CI success", unit: "%", detail: "last #{runs.size} main runs" }
          built = windowed(spec, runs) { |list| success_rate(list) }
          built.merge(state: Rules.verdict("CI success", { value: built[:value] }, health))
        end

        def wall(runs, health)
          spec = { id: "wall", label: "Median CI wall", unit: "min", lower: true,
                   detail: "goal #{health[:wall_goal_minutes]} min" }
          built = windowed(spec, runs.select { |run| run[:status] == "completed" }) do |list|
            median(list.map { |run| run[:wall_minutes] })
          end
          built.merge(state: Rules.verdict("CI wall", { value: built[:value] }, health))
        end

        def failed_head(runs)
          head, before = runs.last(2).reverse
          return unlisted(head) if head[:failed_jobs].nil?

          change = before && trend(before[:failed_jobs], head[:failed_jobs], "jobs", lower_is_better: true)
          state = Rules.verdict("Failed jobs on head", { failed_jobs: head[:failed_jobs] })
          tile("failed_head", "Failed jobs on head", head[:failed_jobs], "jobs",
               detail: "run #{head[:sha]}", trend: change, state: state)
        end

        def unlisted(head)
          unknown_tile("failed_head", "Failed jobs on head", { unknown: "GitHub would not list the jobs of #{head[:sha]}" })
        end

        # How long main has been red, from a {RedReading} of the runs. A run still going has no
        # verdict yet, so the tile says it is running rather than red.
        #
        # @param runs [Array<Hash>] CI runs of main, oldest first
        # @param now [Time] the time the red time is measured to
        # @return [Hash] the tile; its value is nil when no green run in the window starts the count
        def red_for(runs, now)
          reading = RedReading.new(runs, now)
          return running_red(runs.last) unless runs.last[:status] == "completed"
          return tile("red", "Main red for", 0, "h", detail: "main is green") if runs.last[:conclusion] == "success"

          red_tile(reading)
        end

        def red_tile(reading)
          hours = reading.minutes && (reading.minutes / 60.0).round(1)
          tile("red", "Main red for", hours, "h", state: Rules.verdict("Main red", {}), detail: reading.words)
        end

        # The run is still going, so it has no verdict yet: the tile says so rather than red.
        def running_red(latest)
          unknown_tile("red", "Main red for", { unknown: "CI is still running on #{latest[:sha]}" })
        end

        def lead(data, runs)
          spec = { id: "lead", label: "Commit to green CI", unit: "min", lower: true, detail: "landed to green" }
          windowed(spec, runs.select { |run| landed_at(data, run[:sha]) }) do |list|
            median(list.map { |run| (finished(run) - Time.parse(landed_at(data, run[:sha]))) / 60.0 })
          end
        end

        # How long a landed commit waited before the push that CI ran for it.
        def carry(data, runs)
          spec = { id: "carry", label: "Landed to pushed", unit: "min", lower: true, detail: "landed to the push" }
          windowed(spec, runs.select { |run| run[:pushed] && landed_at(data, run[:sha]) }) do |list|
            median(list.map { |run| (Time.parse(run[:pushed]) - Time.parse(landed_at(data, run[:sha]))) / 60.0 })
          end
        end

        # @param spec [Hash] `id`, `label`, `unit`, `detail` and `lower` (a fall is an improvement)
        def windowed(spec, list)
          early, late = halves(list)
          change = trend(yield(early), yield(late), spec[:unit], lower_is_better: spec[:lower] || false)
          tile(spec[:id], spec[:label], yield(list), spec[:unit], detail: spec[:detail], trend: change)
        end
      end
    end
  end
end
