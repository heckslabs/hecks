# frozen_string_literal: true

require "time"
require_relative "ci_tiles"
require_relative "work_tiles"

module Hecks
  module Adapters
    module PipelineBoard
      # The key-metric tiles: each a number, its unit, a state word and a trend against the earlier
      # half of the same window. A section that could not be read gives a tile that says `unknown`.
      module Metrics
        extend CiTiles
        extend WorkTiles

        # @param data [Hash] the board's sections, each an answer or `{unknown: reason}`
        # @param now [Time] the time the tiles are read at
        # @return [Array<Hash>] the tiles, in the order the page shows them
        def self.tiles(data, now)
          runs = data[:ci_runs]
          return [unknown_tile("ci", "CI", runs)] + work(data, now) unless runs.is_a?(Array) && !runs.empty?

          ci(data, runs, now) + work(data, now)
        end

        def self.ci(data, runs, now)
          health = data.fetch(:ci_health, CiTiles::HEALTH_DEFAULTS)
          [success(runs, health), wall(runs, health), failed_head(runs), red_for(runs, now), lead(data, runs), carry(data, runs)]
        end

        def self.work(data, now)
          limits = data.fetch(:push_limits, Hecks::Adapters::PushSize::DEFAULTS)
          [ahead(data[:local], now, limits), working(data), throughput(data[:finished], now), release(data[:release], now)]
        end
      end
    end
  end
end
