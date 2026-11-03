# frozen_string_literal: true

require "open3"

module Hecks
  module Adapters
    module PipelineBoard
      # Keeps main's red flag in step with CI while the board server listens, with no agent session
      # open. Each tick runs `RedFlag.sync!` through the checkout's launcher: the command reads
      # main's newest CI run on GitHub, raises the flag on a red run (once per head) and lowers it
      # on a green one. The command is the bluebook's; this class only sets its cadence.
      class FlagWatch
        # @param root [String] the checkout whose launcher runs the sync
        # @param every [Numeric] seconds between syncs
        # @param runner [#call, nil] takes `(launcher, command, *args, chdir:)` and answers
        #   `[output, status]`; the launcher's own run when nil, and a spec replaces it
        def initialize(root:, every: 60, runner: nil)
          @root = root
          @every = every
          @runner = runner || method(:launch)
        end

        # Starts the thread that syncs on the interval.
        #
        # @return [FlagWatch] self
        def start
          @thread = Thread.new { loop { synced? && sleep(@every) } }
          self
        end

        # Stops the thread.
        #
        # @return [void]
        def stop = @thread&.kill

        # Runs one sync. A failed launch is named on stderr and the next tick tries again.
        #
        # @return [Boolean] whether the launcher answered successfully
        def synced?
          out, status = @runner.call(launcher, "RedFlag.sync!", "checkout.value=#{@root}", "--wait", chdir: @root)
          warn "red flag sync failed: #{last_line(out)}" unless status.success?
          status.success?
        end

        private

        def launcher = File.join(@root, "exe", "hecks")

        def last_line(output) = output.to_s.lines.last

        def launch(*argv, chdir:) = Open3.capture2e(*argv, chdir: chdir)
      end
    end
  end
end
