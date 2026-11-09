# frozen_string_literal: true

require_relative "dispatching"

module Hecks
  module Adapters
    # The `Waking` port's adapter for `Wake`: each beat of the clock asks whether the clock
    # alone has made something eligible to start, which the {Dispatching} adapter answers from
    # the planned items, the boot budget and the rolls it refused. It reads in this process and
    # starts nothing.
    class Waking
      # @param registry [Runtime::Registry, nil] the booted registry whose work items are read
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] stand-ins for the machine and the clock
      # @param root [String, nil] unused
      def initialize(registry: nil, aggregate: nil, settings: {}, root: nil)
        @dispatching = Dispatching.new(registry: registry, settings: settings)
      end

      # @param held [Hash] the `Wake` record
      # @return [Hash{Symbol => Hash}] `roll:` the key of the roll to start and `reason:` why
      # @raise [ConsoleCapture::Failure] when rolling is paused or nothing has become eligible
      def notice(**held) = @dispatching.notice(**held)
    end
  end
end
