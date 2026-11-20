# frozen_string_literal: true

require_relative "plan_admission"

module Hecks
  module Adapters
    class Dispatching
      # What a quiet beat of the clock says. Under admission by headroom the beat's own plan may
      # have left the planned work waiting on Signalbox; the quiet refusal then names the given that
      # held it, so a stall can be read from the beat's log alone.
      module QuietBeat
        # The refusal of a beat that found nothing eligible.
        QUIET = "quiet: nothing has become eligible by the clock"

        module_function

        # @param held [String, nil] the `skipped: signalbox:` reason the beat's plan gave, if any
        # @return [String] the quiet refusal, naming the admission's given when one held the room
        def message(held) = held ? "#{QUIET}; #{held}" : QUIET

        # @param plan [Plan] the plan the beat made for its free slots
        # @param held [Array] collects the reason admission held an item, nil when none
        # @return [Integer] how many planned items that plan would start
        def starts(plan, held)
          held << admission_held(plan)
          plan.chosen.size
        end

        # @param plan [Plan] the plan the beat made for its free slots
        # @return [String, nil] the first reason Signalbox's admission left an item waiting with
        def admission_held(plan)
          plan.skipped.find { |skip| skip.reason.start_with?(PlanAdmission::ADMISSION) }&.reason
        end
      end
    end
  end
end
