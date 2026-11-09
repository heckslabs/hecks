# frozen_string_literal: true

require_relative "../../hecks/adapters/boot_budget"
require_relative "../../hecks/adapters/dispatching/settings"

module Hecks
  module Adapters
    # The `Boots` reader: what the launcher's boots cost today, from the usage record, with the
    # load average against the one threshold the Tickets world sets. It reads, decides nothing
    # and writes nothing.
    class PipelineBoots
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] `entries:` answers the usage entries of a day, `load:` the load
      #   average, `now:` the time
      # @param registry [Runtime::Registry, nil] whose Tickets world sets the budget and the limit
      def initialize(aggregate: nil, settings: {}, registry: nil)
        @budget = BootBudget.new(entries: settings[:entries], now: settings[:now])
        @machine = Dispatching::Settings.new(registry, load: settings[:load])
      end

      # @return [Hash] `hours`, `boots`, `unmeasured`, `approximate` (runs placed by their day
      #   alone), `truncated` (the byte limit cut the read short, so `hours` is a floor),
      #   `last_hour` (callers to runs), `budget` (hours a day, nil when none is set), `load` and
      #   `max_load`
      def today
        reading = @budget.today
        { hours: reading.hours, boots: reading.boots, unmeasured: reading.unmeasured,
          approximate: reading.approximate, truncated: reading.capped, last_hour: reading.last_hour,
          budget: @machine.boot_budget, load: @machine.load.round(1), max_load: @machine.max_load.round(1) }
      end
    end
  end
end
