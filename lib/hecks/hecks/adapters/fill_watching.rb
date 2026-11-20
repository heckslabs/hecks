# frozen_string_literal: true

require_relative "dispatching"
require_relative "dispatching/fill_stall"

module Hecks
  module Adapters
    # The `FillWatching` port's adapter for `FillWatch`: each beat asks whether the fill has
    # started nothing for a window while planned work waits and the preview shows room. It reads
    # the same plan the preview reads, in this process, and starts nothing.
    class FillWatching
      # @param registry [Runtime::Registry, nil] the booted registry whose work items are read
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] stand-ins for the machine and the clock
      # @param root [String, nil] unused
      def initialize(registry: nil, aggregate: nil, settings: {}, root: nil)
        @dispatching = Dispatching.new(registry: registry, settings: settings)
      end

      # @param held [Hash] the `FillWatch` record
      # @return [Hash{Symbol => Hash}] `reason:`, `reading:`, `held_minutes:` and `governed_by:`
      # @raise [ConsoleCapture::Failure] when a start is recent, nothing waits, or there is no room
      def look(**held) = @dispatching.look_at_fill(**held)
    end
  end
end
