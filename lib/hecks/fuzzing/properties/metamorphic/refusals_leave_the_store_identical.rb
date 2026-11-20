# frozen_string_literal: true

module Hecks
  module Fuzzing
    module Properties
      module Metamorphic
        # A refused command leaves the store as it found it: the session's instances read before
        # and after every refused verb step are equal. The instances part of the Ruby battery's
        # `refusals_leave_no_trace`, judged by nothing but the kernel's own answers.
        module RefusalsLeaveTheStoreIdentical
          module_function

          # Plays the steps in a fresh session and compares the store around each refusal.
          #
          # @param probe [Probe] a greeted serve connection
          # @param steps [Array<Hash>] playable steps
          # @return [true, String] true, or which refused step changed the store
          def call(probe, steps)
            probe.session do |name|
              index = steps.each_index.find { |at| changed_on_refusal?(probe, name, steps[at]) }
              index.nil? || "refused step #{index} (#{steps[index]["verb"]}) changed the store"
            end
          end

          # @return [Boolean] whether the step was a refused dispatch that changed the store
          def changed_on_refusal?(probe, name, step)
            before = probe.instances(name)
            played = probe.send_step(name, step)
            played.verb? && !played.ok? && probe.instances(name) != before
          end
        end
      end
    end
  end
end
