# frozen_string_literal: true

require_relative "admission_switch"
require_relative "admitting"

module Hecks
  module Adapters
    class Dispatching
      # What a filling reads of admission by headroom: with the owner's `admission.signalbox`
      # switch on, the `admit:` limit its plan asks in place of the cap, and the clause its header
      # says in place of `started N of cap C`. It reads the work items, machine and stand-ins of the
      # {Dispatching} that includes it; the stand-in `admitting:` replaces the Signalbox door.
      module AdmissionReads
        private

        # @return [Hash] `admit:` with the switch on, else nothing, so the cap and the reserve hold
        def admission_limit
          admitting ? { admit: admitting } : {}
        end

        # @return [String] the started count against the cap, or the admission's own clause
        def cap_clause
          started = work_items.started.size
          admitting ? "started #{started}; #{admitting.clause}" : "started #{started} of cap #{machine.cap}"
        end

        def admitting
          return @standins[:admitting] if @standins.key?(:admitting)
          return unless AdmissionSwitch.on?(@registry)

          @admitting ||= Admitting.new(runs: work_items.runs, now: @standins[:now]&.call || Time.now,
                                       switch: WorkLimits.switch_on?(@registry), meter: Admitting.meter(@registry))
        end
      end
    end
  end
end
