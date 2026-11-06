# frozen_string_literal: true

require_relative "../red_main"
require_relative "../red_main_line"

module Hecks
  module Adapters
    class GitTrain
      # The train's stop while main is red: a boarding that names no open red row it fixes is refused
      # before anything is settled, minted or pushed. An unknown state (`gh` failed) refuses nothing
      # and says so in the report's lead line.
      class RedStop
        # @param registry [Runtime::Registry, nil] its Hecks world declares the stop, Tickets holds the rows
        # @param checkout [String] the repository's top level
        # @param options [Hash] `reader:` and `clock:` stand in for GitHub and the time
        def initialize(registry, checkout, **options)
          @registry = registry
          @checkout = checkout
          @options = options
        end

        # @return [RedMain::State] read once per boarding
        def state = @state ||= RedMain.state(@registry, checkout: @checkout, **@options)

        # @return [String] the STOP line or the unknown notice that opens the report, else ""
        def lead = state.lead

        # @param fixes [String, nil] the red row the boarding says it fixes
        # @raise [ConsoleCapture::Failure] while main is red and `fixes` is not an open red row
        def check!(fixes)
          return unless state.red?
          return if fixes && open?(fixes)

          raise ConsoleCapture::Failure, RedMainLine.refusal(state, @registry, fixes: fixes)
        end

        private

        def open?(fixes) = RedMainLine.open_red_rows(@registry).any? { |row| row[:id].to_s == fixes }
      end
    end
  end
end
