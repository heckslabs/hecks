# frozen_string_literal: true

require_relative "tile_kit"

module Hecks
  module Adapters
    module PipelineBoard
      # The tile that reads the disk: the room left on the volume holding the checkout, against the
      # attention and failure floors the Hecks world's `disk_health` line sets.
      module DiskTiles
        include TileKit

        extend DiskTiles

        # The floors when the Hecks world declares no `disk_health` line, in gigabytes free.
        HEALTH_DEFAULTS = { attention_gb: 20, failed_gb: 5 }.freeze

        # @param registry [Runtime::Registry, nil]
        # @return [Hash{Symbol => Integer}] the free-space floors, in gigabytes
        def self.health(registry)
          world = registry&.world("Hecks")
          declared = world ? world.for_verb("disk_health") : {}
          HEALTH_DEFAULTS.merge(declared.slice(*HEALTH_DEFAULTS.keys)).transform_values { |value| Integer(value) }
        end

        # @param reading [Hash] `free_gb`, `total_gb` and `used_percent`, or `{unknown: reason}`
        # @param floors [Hash] the free-space floors, in gigabytes
        # @return [Hash] the tile
        def disk(reading, floors)
          return unknown_tile("disk", "Disk free", reading) unless readable?(reading)

          detail = "#{reading[:used_percent]}% of #{reading[:total_gb]} GB used"
          tile("disk", "Disk free", reading[:free_gb], "GB", state: disk_state(reading[:free_gb], floors), detail: detail)
        end

        private

        def readable?(section) = section.is_a?(Hash) && !section.key?(:unknown)

        def disk_state(free, floors)
          return "failed" if free <= floors[:failed_gb]

          free <= floors[:attention_gb] ? "attention" : "ok"
        end
      end
    end
  end
end
