# frozen_string_literal: true

require_relative "pressure_limits"
require_relative "live_runs"

module Hecks
  module Adapters
    class Dispatching
      # What a filling reads of the machine's room: the limit its plan is given and the clause its
      # header says. It reads the work items, machine and stand-ins of the {Dispatching} that
      # includes it.
      module HeadroomReads
        private

        # The work items that hold a seat under the cap: started, or planned beside a live run.
        def live_holders = LiveRuns.holders(work_items.started, work_items.planned, work_items.runs)

        # The sessions the load has room for, from the stand-in `loads:` or the recent Machine
        # readings. Absent when no reading is recorded, so the cap and the load limit alone apply.
        # While Signalbox's signal drives the fill, its limits ({PressureLimits}) stand over these
        # and over the pause and the load limit they follow in a filling's limits. With the
        # `admission.signalbox` switch on it also carries `admit:` ({AdmissionReads}).
        def headroom_limit(gauge)
          loads = @standins[:loads] || Headroom.loads(@registry)
          estimate = headroom_for(gauge, loads)
          { headroom: estimate.room, per_session: estimate.per_session.round(1),
            **PressureLimits.of(@registry, signal: @standins[:pressure]), **admission_limit }
        end

        def headroom_for(gauge, loads)
          Headroom.new(loads: loads, started: live_holders.size, load: gauge.load, max_load: gauge.max_load)
        end

        # Where the compared load came from and the sampler's newest reading beside it.
        def load_reading_clause
          sampled = (@standins[:loads] || Headroom.loads(@registry, count: 1)).last
          LoadReading.new(load: machine.load, sampled: sampled, at: ran_at, source: machine.load_source).clause
        end

        # `headroom 2 of cap 7 (1.6 load per session)`: the sessions the load has room for (an
        # estimate), beside the cap that stays the ceiling and the load one session is taken to
        # cost. With no reading there is no room to state and no cost to claim: `headroom unread`.
        def headroom_clause(plan)
          clause = "headroom #{plan.headroom || "unread"} of cap #{machine.cap}"
          plan.headroom && plan.per_session ? "#{clause} (#{plan.per_session} load per session)" : clause
        end
      end
    end
  end
end
