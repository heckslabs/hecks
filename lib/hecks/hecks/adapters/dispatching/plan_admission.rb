# frozen_string_literal: true

module Hecks
  module Adapters
    class Dispatching
      # A {Plan}'s admission by headroom: with the owner's `admission.signalbox` switch on, the
      # plan's `admit:` limit ({Admitting}) admits each coder in place of the cap and the red
      # reserve. The coders the plan already chose take their draw off the headroom, and the ones it
      # left waiting by admission outrank the rest.
      module PlanAdmission
        # The reason a work item Signalbox did not admit waits with.
        ADMISSION = "skipped: signalbox:"

        private

        def admission_reason(item)
          waiting = @skipped.count { |skip| skip.reason.start_with?(ADMISSION) }
          @limits[:admit].reason(item, chosen: chosen_seats, outranked: waiting)
        end
      end
    end
  end
end
