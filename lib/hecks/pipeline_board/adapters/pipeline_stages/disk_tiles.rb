# frozen_string_literal: true

require_relative "tile_kit"
require_relative "../rules"

module Hecks
  module Adapters
    module PipelineBoard
      # The tile that reads the disk: the room left on the volume holding the checkout, against the
      # attention and failure floors the Hecks world's `disk_health` line sets.
      module DiskTiles
        include TileKit

        extend DiskTiles

        # The `Setting` each word of the Hecks world's `disk_health` line overrides.
        WORLD_WORDS = { attention_gb: :disk_attention_gb, failed_gb: :disk_failed_gb }.freeze

        # @param registry [Runtime::Registry, nil]
        # @return [Hash{Symbol => Integer}] the floors the world's `disk_health` line declares, by
        #   the `Setting` each one overrides; none when the world declares no such line
        def self.health(registry)
          world = registry&.world("Hecks")
          declared = world ? world.for_verb("disk_health") : {}
          declared.slice(*WORLD_WORDS.keys).to_h { |word, value| [WORLD_WORDS.fetch(word), Integer(value)] }
        end

        # @param reading [Hash] `free_gb`, `total_gb` and `used_percent`, or `{unknown: reason}`
        # @param floors [Hash] the floors that outrank the `Setting` rows, in gigabytes
        # @return [Hash] the tile
        def disk(reading, floors)
          return unknown_tile("disk", "Disk free", reading) unless readable?(reading)

          detail = "#{reading[:used_percent]}% of #{reading[:total_gb]} GB used"
          tile("disk", "Disk free", reading[:free_gb], "GB", state: disk_state(reading[:free_gb], floors), detail: detail)
        end

        private

        def readable?(section) = section.is_a?(Hash) && !section.key?(:unknown)

        def disk_state(free, floors) = Rules.verdict("Disk free", { free_gb: free }, floors)
      end
    end
  end
end
