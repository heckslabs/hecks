# frozen_string_literal: true

require "time"
require_relative "tile_kit"
require_relative "../rules"

module Hecks
  module Adapters
    module PipelineBoard
      # The tile that reads the open pull requests: how many are open, how long the oldest has
      # waited and which train pull request is open. The `Open PRs` rows of the bluebook decide
      # when the wait needs attention.
      module PrTiles
        include TileKit

        extend PrTiles

        # @param reading [Hash] what `PipelineGitHub#open_prs` answered, or `{unknown: reason}`
        # @param now [Time] the time the age is read at
        # @return [Hash] the tile
        def open_prs(reading, now)
          return unknown_tile("open_prs", "Open PRs", reading) unless reading.is_a?(Hash) && !reading.key?(:unknown)

          age = reading[:oldest] ? ((now - Time.parse(reading[:oldest])) / 3600.0).round(1) : 0.0
          state = Rules.verdict("Open PRs", { oldest_hours: age })
          tile("open_prs", "Open PRs", reading[:count], reading[:capped] ? "open (limit)" : "open",
               state: state, detail: pr_detail(reading, age))
        end

        private

        def pr_detail(reading, age)
          return "none open" if reading[:count].zero?

          train = reading[:train] ? "train PR ##{reading[:train]}" : "no train PR"
          "oldest #{age} h; #{train}"
        end
      end
    end
  end
end
