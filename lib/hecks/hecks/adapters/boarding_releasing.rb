# frozen_string_literal: true

require_relative "boarding_hold_marking"

module Hecks
  module Adapters
    # The `Releasing` port's adapter for `BoardingRelease`: removes the marker that holds local
    # main, whoever took it. A release with nothing held is a no-op.
    class BoardingReleasing
      include BoardingHoldMarking

      # @param aggregate [Object, nil] unused
      # @param settings [Hash] `minutes:` the window and `clock:`, for a spec
      # @param root [String, nil] unused
      # @param registry [Runtime::Registry, nil] where the world's `boarding_hold` setting is read
      def initialize(aggregate: nil, settings: {}, root: nil, registry: nil)
        @git = Git.new
        @settings = settings
        @registry = registry
      end

      # Lifts the hold.
      #
      # @param held [Hash] the `BoardingRelease` record: `checkout`
      # @return [Hash{Symbol => Hash}] `output:` what was released
      # @raise [ConsoleCapture::Failure] when the checkout is not a repository
      def clear(**held)
        removed = marker_of(held).release!
        said = removed ? "boarding #{removed.boarding[0, 9]} by #{removed.owner}" : "no hold"
        { output: { value: "released: #{said}" } }
      end
    end
  end
end
