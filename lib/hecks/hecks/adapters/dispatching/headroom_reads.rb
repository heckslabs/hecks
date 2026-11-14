# frozen_string_literal: true

module Hecks
  module Adapters
    class Dispatching
      # What a filling reads of the machine's room: the limit its plan is given and the clause its
      # header says. It reads the work items, machine and stand-ins of the {Dispatching} that
      # includes it.
      module HeadroomReads
        private

        # The sessions the load has room for, from the stand-in `loads:` or the recent Machine
        # readings. Absent when no reading is recorded, so the cap and the load limit alone apply.
        def headroom_limit(gauge)
          loads = @standins[:loads] || Headroom.loads(@registry)
          estimate = headroom_for(gauge, loads)
          { headroom: estimate.room, per_session: estimate.per_session.round(1) }
        end

        def headroom_for(gauge, loads)
          Headroom.new(loads: loads, started: work_items.started.size, load: gauge.load, max_load: gauge.max_load)
        end

        # `headroom 2 of cap 7 (1.6 load per session)`: the sessions the load has room for (an
        # estimate), beside the cap that stays the ceiling and the load one session is taken to
        # cost. With no reading there is no room to state and no cost to claim: `headroom unread`.
        def headroom_clause(plan)
          clause = "headroom #{plan.headroom || "unread"} of cap #{machine.cap}"
          plan.headroom ? "#{clause} (#{plan.per_session} load per session)" : clause
        end
      end
    end
  end
end
