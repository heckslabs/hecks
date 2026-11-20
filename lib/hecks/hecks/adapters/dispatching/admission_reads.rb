# frozen_string_literal: true

require_relative "admission_switch"
require_relative "admitting"

module Hecks
  module Adapters
    class Dispatching
      # What a filling reads of admission by headroom: with the owner's `admission.signalbox`
      # switch on, the `admit:` limit its plan asks in place of the cap, and the clause its header
      # says in place of `started N of cap C`, and the ruling it makes just before each start. It
      # reads the work items, machine and stand-ins of the {Dispatching} that includes it; the
      # stand-in `admitting:` replaces the Signalbox door.
      module AdmissionReads
        private

        # A chosen work item admission refuses just before its start waits, and is never started,
        # so no `WorkStarted` stands for a start admission refuses.
        #
        # @param item [Plan::Item] the chosen work item
        # @return [FillReport::Outcome, nil] the wait, nil when the item may start
        def waiting_outcome(item)
          refused = admission_before_start(item)
          FillReport::Outcome.new(:waiting, "#{item.key} waits: #{refused}") if refused
        end

        # The plan's beat was read when the fill began; a start is ruled on a beat read just before
        # it. An expedited item passed the short band in the plan (ADR 0224), so the plan's ruling
        # is granted as it stands and the start's check keeps it.
        def admission_before_start(item)
          return unless admitting
          return grant_plan_ruling(item) if WorkItems.expedited?(item)

          (@standins.key?(:admitting) ? admitting : fresh_admitting).admit!(item)
        end

        # @return [nil] the item may start, its plan's ruling granted to the start's check
        def grant_plan_ruling(item)
          AdmissionGrants.grant(item.key, at: admission_now)
          nil
        end

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

          @admitting ||= fresh_admitting
        end

        # An admission over a beat read now, counting the runs recorded so far, the ones this fill
        # started included.
        def fresh_admitting
          Admitting.new(runs: work_items.runs, now: admission_now, switch: WorkLimits.switch_on?(@registry),
                        meter: Admitting.meter(@registry))
        end

        def admission_now = @standins[:now]&.call || Time.now
      end
    end
  end
end
