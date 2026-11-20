# frozen_string_literal: true

module Hecks
  module Fuzzing
    module Properties
      module Metamorphic
        # A dry run predicts its dispatch: on the same store, a verb step's dry run is accepted
        # exactly when the step itself is. The serve form of the Ruby battery's
        # `validation_agrees_with_dry_run`.
        module DryRunAgreesWithDispatch
          module_function

          # Plays the steps in a fresh session, dry-running each verb step just before it.
          #
          # @param probe [Probe] a greeted serve connection
          # @param steps [Array<Hash>] playable steps
          # @return [true, String] true, or which step its dry run mispredicted
          def call(probe, steps)
            probe.session do |name|
              index = steps.each_index.find { |at| mispredicted?(probe, name, steps[at]) }
              index.nil? || "step #{index} (#{steps[index]["verb"]}): its dry run and its dispatch disagree"
            end
          end

          # @return [Boolean] whether a verb step's dry run and dispatch disagreed on acceptance
          def mispredicted?(probe, name, step)
            dry = step.key?("verb") && probe.send_step(name, Probe.dry_run_of(step))
            real = probe.send_step(name, step)
            dry ? dry.ok? != real.ok? : false
          end
        end
      end
    end
  end
end
