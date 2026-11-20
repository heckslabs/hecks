# frozen_string_literal: true

require_relative "started_work"
require_relative "area_overlap"

module Hecks
  module Adapters
    # The `Claims` port's adapter: the ground this repository's pipeline holds a landing off.
    #
    # Delivery asks it and knows neither answer's source. The claims that stand are the started
    # `Tickets::Work` items, each with its area ({StartedWork}), and an area holds a changed file
    # by the one overlap rule a Work item's claim is checked with ({AreaOverlap}).
    class LandingClaims
      # @param registry [Runtime::Registry, nil] the booted registry the Work items are read from
      def initialize(registry: nil)
        @registry = registry
      end

      # @return [Hash{Symbol => Array<Hash>}] `claims:`, the `key:` and `area:` of each started
      #   Work item
      def read_claims(**)
        { claims: StartedWork.items(@registry) }
      end

      # @param area [String] an area a started Work item holds
      # @param file [String] a file a landing changes
      # @param root [String] the repository's top level
      # @return [Hash{Symbol => Boolean}] `overlaps:`, whether the area holds the file
      def overlap(area:, file:, root:, **)
        { overlaps: AreaOverlap.overlap?(area, file, root: root, file: true) }
      end
    end
  end
end
