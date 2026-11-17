# frozen_string_literal: true

require_relative "../shell"
require_relative "../console_capture"
require_relative "../codebase/heavy_slots"
require_relative "../git_shallow_check/impacted_run"
require_relative "command_runner"
require_relative "load"

module Hecks
  module Adapters
    class MainIntegration
      # The check of a verification that runs the specs a range of landings touched, in the clean
      # copy of main, through the same machinery a landing's shallow check uses
      # ({GitShallowCheck::ImpactedRun}) and within the same budget, the world's `spec_bounds`
      # `impacted_seconds`. It holds one heavy-job place for its whole run, as the shallow check
      # does, so the launcher calls it starts take none of their own.
      #
      # It answers as a command runner does, `[ok, output]`, so a red spec fails the verification
      # exactly as a red quick gate does. Specs the budget left unrun are not a failure: the
      # output says how many.
      class ImpactedCheck
        # The check's name in a verification's report and refusals.
        NAME = "impacted specs"

        # The heavy-job class the check takes a place as.
        JOB = "main_verification"

        # Runs the launcher in the copy as the quick gate runs: under Bundler, with the variables
        # that would point it at another checkout left out.
        class Launched
          # @return [Shell::Result]
          def capture(*argv, env:, chdir:)
            command = [*Load.prefix(chdir), *Checks::RUNS_AS, *argv]
            Shell.new.capture(*command, env: CommandRunner.environment.merge(env), chdir: chdir)
          end
        end

        # @param directory [String] the clean copy of the commit being verified
        # @param changed [Array<String>] the paths the range changed
        # @param since [String] the commit the range starts after
        # @param run [#call, nil] stands in for the impacted-spec run: given the changed paths and
        #   the commit, answers an {GitShallowCheck::ImpactedRun::Outcome}
        def initialize(directory, changed, since, run: nil)
          @directory = directory
          @changed = changed
          @since = since
          @run = run || method(:in_a_place)
        end

        # @return [Array(Boolean, String)] whether every impacted spec passed, and what it said
        def call(**)
          done = @run.call(@changed, @since)
          [true, "#{done.ran.size} impacted spec files green in #{done.calls} launcher calls, #{done.seconds} s#{unrun(done)}"]
        rescue ConsoleCapture::Failure => e
          [false, e.message]
        end

        # @return [Array<String>] what a failure log names as the command
        def to_a = ["impacted specs since", @since, "in", @directory]

        private

        # The landing's worker count, held to the world's `main_verification` cap.
        def held_workers
          landing = GitShallowCheck::ImpactedWorkers.from_world(@directory)
          cap = Load.workers(@directory)
          ->(specs) { [landing.call(specs), cap || specs].min }
        end

        def unrun(done) = done.unrun.empty? ? "" : "; #{done.unrun.size} files not run: the budget was spent"

        def in_a_place(changed, since)
          done, = Codebase::HeavySlots.held(@directory, JOB) do
            GitShallowCheck::ImpactedRun.new(@directory, shell: Launched.new, workers: held_workers).call(changed, since)
          end
          done
        end
      end
    end
  end
end
