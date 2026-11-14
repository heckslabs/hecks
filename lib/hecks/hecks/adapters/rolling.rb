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
        @world = Dispatching::Settings.new(registry)
      end

      # Answers the owner's switch as the Tickets world says it now, and the pause the `RollSwitch`
      # record it is handed holds, so the bluebook decides whether a roll starts.
      #
      # @param held [Hash] the `RollSwitch` record: `paused`, and the `run` that asks
      # @return [Hash{Symbol => String, Integer}] `state:` "on" or "off", `standing:` 1 while a
      #   pause is recorded and 0 otherwise
      def read(**held)
        paused = held[:paused]
        { state: @world.roll_forward? ? "on" : "off", standing: (paused.is_a?(Hash) ? paused[:value] : paused).to_i }
      end

      # @param held [Hash] the `Roll` record
      # @return [Hash{Symbol => Hash}] `report:` what the filling started and what waits
      # @raise [ConsoleCapture::Failure] when rolling is paused or nothing changed
      def roll(**held) = @dispatching.roll(**held)
    end
  end
end
