# frozen_string_literal: true

require_relative "../machine_sampling/marks"
require_relative "fill_gauge"
require_relative "stall_reading"

module Hecks
  module Adapters
    class Dispatching
      # The question a beat of the clock, and each start, puts to the queue: does the fill stand
      # stalled. It reads the same work items, machine and plan as the rest of {Dispatching}, which
      # includes this module, and answers facts; the Delegate bluebook's `FillStall` policies
      # decide. It starts nothing and writes nothing.
      module StallGauging
        # @param held [Hash] the `FillStall` record: `standing`, the stall it records, and `since`,
        #   the time its idle minutes are counted from
        # @return [Hash{Symbol => Object}] `standing:` as held; `waiting:`, `room:`, `chosen:`,
        #   `idle_minutes:`, `since:` and `now:` (see {FillGauge#facts}); and `reason:`,
        #   `reading:` and `governed_by:` (see {StallReading#to_h})
        def gauge(**held)
          plan = stall_plan
          { standing: plain(held[:standing]).to_i, **stall_counts(plan).facts(since: plain(held[:since]).to_s, now: clock),
            **stall_reading(plan).to_h }
        end

        private

        # The plan a rolling filling would make now, from the items the beat keeps; none when
        # nothing is planned, so an empty queue costs no read of the machine.
        def stall_plan
          items = beat_items
          Plan.new(items, work_items.started, **limits) unless items.empty?
        end

        # The owner's pause starts nothing, whatever the plan would choose.
        def stall_counts(plan)
          chosen = plan && machine.roll_forward? ? plan.chosen.size : 0
          FillGauge.new(waiting: beat_items.size, started: work_items.started.size, cap: machine.cap, chosen: chosen)
        end

        def stall_reading(plan)
          gauge = machine
          StallReading.new(plan ? plan.skipped : [], rolling: gauge.roll_forward?, waiting: beat_items.size, load: gauge.load,
                                                     source: gauge.load_source, max_load: gauge.max_load, load_high: MachineSampling::Marks.of(@registry)[:load_high])
        end
      end
    end
  end
end
