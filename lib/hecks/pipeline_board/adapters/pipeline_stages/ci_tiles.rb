# frozen_string_literal: true

require_relative "tile_kit"

module Hecks
  module Adapters
    module PipelineBoard
      # The tiles that read CI: success rate, wall time against the goal, failed jobs on the head,
      # how long main has been red, and how long a commit takes to get a green CI.
      module CiTiles
        include TileKit

        GOAL_MINUTES = 3

        # @param runs [Array<Hash>] CI runs, oldest first
        def success(runs)
          spec = { id: "success", label: "CI success", unit: "%", detail: "last #{runs.size} main runs" }
          built = windowed(spec, runs) { |list| success_rate(list) }
          built.merge(state: band(built[:value], 80, 50))
        end

        def wall(runs)
          spec = { id: "wall", label: "Median CI wall", unit: "min", lower: true, detail: "goal #{GOAL_MINUTES} min" }
          built = windowed(spec, runs.select { |run| run[:status] == "completed" }) do |list|
            median(list.map { |run| run[:wall_minutes] })
          end
          built.merge(state: over(built[:value], GOAL_MINUTES))
        end

        def failed_head(runs)
          head, before = runs.last(2).reverse
          return unlisted(head) if head[:failed_jobs].nil?

          change = before && trend(before[:failed_jobs], head[:failed_jobs], "jobs", lower_is_better: true)
          state = head[:failed_jobs].zero? ? "ok" : "failed"
          tile("failed_head", "Failed jobs on head", head[:failed_jobs], "jobs",
               detail: "run #{head[:sha]}", trend: change, state: state)
        end

        def unlisted(head)
          unknown_tile("failed_head", "Failed jobs on head", { unknown: "GitHub would not list the jobs of #{head[:sha]}" })
        end

        # A run still going has no verdict yet, so the tile says it is running rather than red.
        def red_for(runs, now)
          latest = runs.last
          return running_red(latest) unless latest[:status] == "completed"
          return tile("red", "Main red for", 0, "h", detail: "main is green") if latest[:conclusion] == "success"

          green = runs.index { |run| run[:conclusion] == "success" }
          hours = green && ((now - finished(runs[green])) / 3600.0).round(1)
          tile("red", "Main red for", hours, "h", state: "failed", detail: red_note(runs, green))
        end

        # Names the last green commit and the first red one after it. The runs are newest first, so
        # the first red is the run just before the green one in the list.
        def red_note(runs, green)
          return "no green run in the window" unless green
          return "last green #{runs[green][:sha]}" if green.zero?

          "last green #{runs[green][:sha]}, first red #{runs[green - 1][:sha]}"
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

        def band(value, good, fair)
          return "unknown" if value.nil?
          return "ok" if value >= good

          value >= fair ? "attention" : "failed"
        end

        def over(value, goal)
          return "unknown" if value.nil?
          return "ok" if value <= goal

          value <= goal * 2 ? "attention" : "failed"
        end
      end
    end
  end
end
