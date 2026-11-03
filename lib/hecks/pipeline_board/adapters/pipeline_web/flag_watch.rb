# frozen_string_literal: true

require "hecks/hecks/adapters/main_integration/command_runner"

module Hecks
  module Adapters
    module PipelineBoard
      # Keeps main's red flag in step with CI while the board runs: each `every` seconds it reads
      # main's newest CI run (the same `gh` read the CI tiles make, cached with them) and, when a
      # run has completed that it has not acted on, asks `RedFlag.sync!` through the launcher, at
      # top level, which raises or lowers the flag and emits the event every session hears. A run
      # acted on once is not acted on again, `sync!` itself records a run only once, and nothing
      # from HTTP reaches this: the server has no route to it. The world's `red_flag` setting
      # `board_sync_seconds` sets the cadence; 0 switches the watch off.
      class FlagWatch
        # The world verb and key the cadence is read from.
        SETTING = %w[red_flag board_sync_seconds].freeze

        # The launcher of the running copy of Hecks, which `sync!` is asked through.
        LAUNCHER = File.expand_path("../../../../../exe/hecks", __dir__)

        # @param registry [Runtime::Registry, nil] the booted registry whose Hecks world is read
        # @return [Integer] the seconds between looks, 0 when the world names none
        def self.cadence(registry)
          settings = registry&.world("Hecks")&.for_verb(SETTING.first)
          settings.to_h.fetch(SETTING.last.to_sym, 0).to_i
        end

        # @param github [#latest_run] the board's GitHub reader
        # @param every [Integer] seconds between looks; 0 never looks
        # @param root [String] the checkout the launcher runs in
        # @param sync [#call, nil] what asks `RedFlag.sync!`; the launcher when nil
        def initialize(github:, every:, root:, sync: nil)
          @github = github
          @every = every.to_i
          @root = root
          @sync = sync || method(:launch)
          @acted = nil
        end

        # @return [Boolean] whether the watch looks at all
        def on? = @every.positive?

        # Starts looking on a thread of its own.
        # @return [FlagWatch] self
        def start
          @thread = Thread.new { look_forever } if on?
          self
        end

        # Stops looking.
        def stop = @thread&.kill

        # Looks once: acts on a newly completed run, leaves anything else alone.
        #
        # @return [Integer, nil] the run acted on, nil when none was
        def tick
          run = @github.latest_run
          return unless run && run[:status] == "completed" && run[:id] != @acted

          @acted = run[:id]
          @sync.call
          @acted
        rescue Unavailable
          nil
        end

        private

        def look_forever
          loop do
            tick
            sleep @every
          end
        end

        def launch
          MainIntegration::CommandRunner.new.call([LAUNCHER, "RedFlag.sync!", "--wait"], chdir: @root)
        end
      end
    end
  end
end
