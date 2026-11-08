# frozen_string_literal: true

require_relative "dispatching"

module Hecks
  module Adapters
    # The `Rolling` port's adapter for `Roll`: a rolling fill is one confirmed filling of the queue,
    # so it is answered by the {Dispatching} adapter, which holds the ordering and every guard.
    class Rolling
      # @param registry [Runtime::Registry, nil] the booted registry whose work items are read
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] stand-ins for the machine and the launcher
      # @param root [String, nil] unused
      def initialize(registry: nil, aggregate: nil, settings: {}, root: nil)
        @dispatching = Dispatching.new(registry: registry, settings: settings)
      end

      # @param held [Hash] the `Roll` record
      # @return [Hash{Symbol => Hash}] `report:` what the filling started and what waits
      # @raise [ConsoleCapture::Failure] when rolling is paused or nothing changed
      def roll(**held) = @dispatching.roll(**held)
    end
  end
end
