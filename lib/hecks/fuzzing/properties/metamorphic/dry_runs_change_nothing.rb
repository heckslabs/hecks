# frozen_string_literal: true

module Hecks
  module Fuzzing
    module Properties
      module Metamorphic
        # A dry run changes nothing: before each verb step is dispatched, its dry run on the same
        # store leaves the session's instances as they were. The serve form of the Ruby battery's
        # `dry_runs_leave_no_trace`.
        module DryRunsChangeNothing
          module_function

          # Plays the steps in a fresh session, dry-running each verb step first.
          #
          # @param probe [Probe] a greeted serve connection
          # @param steps [Array<Hash>] playable steps
          # @return [true, String] true, or which dry run changed the store
          def call(probe, steps)
            probe.session do |name|
              index = steps.each_index.find { |at| !still?(probe, name, steps[at]) }
              index.nil? || "the dry run of step #{index} (#{steps[index]["verb"]}) changed the store"
            end
          end

          # Dry-runs a verb step, then plays the step itself.
          #
          # @return [Boolean] whether the dry run, when the step has one, left the store alone
          def still?(probe, name, step)
            unchanged = !step.key?("verb") || begin
              before = probe.instances(name)
              probe.send_step(name, Probe.dry_run_of(step))
              probe.instances(name) == before
            end
            probe.send_step(name, step)
            unchanged
          end
        end
      end
    end
  end
end
