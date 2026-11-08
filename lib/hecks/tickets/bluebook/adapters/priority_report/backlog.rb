# frozen_string_literal: true

require "hecks/hecks/adapters/started_work"
require "hecks/hecks/adapters/push_size"

module Hecks
  module Adapters
    class PriorityReport
      # The open work items as rows: the started ones, which already hold their slots, then the
      # planned ones in the order {Dispatching::WorkItems} gives them, each with the reason it
      # waits when {Dispatching::Plan} left it waiting.
      class Backlog
        # One line of the report.
        Row = Struct.new(:position, :tier, :step, :key, :status, :area, :note)

        # The tier of an item that is red.
        RED = "red"

        # The tier of an item nobody ranked.
        UNRANKED = "none"

        # @param items [Dispatching::WorkItems] the one ordering
        # @param plan [Dispatching::Plan] says why a planned item waits
        # @param registry [Runtime::Registry, nil] read for each item's step and priority
        def initialize(items, plan, registry)
          @items = items
          @plan = plan
          @facts = facts(registry)
        end

        # @return [Array<Row>] started items first, then planned items in dispatch order
        def rows
          ordered = @items.started.map { |item| [item, "started", "holds its slot"] } +
                    @items.planned.map { |item| [item, "planned", note(item)] }
          ordered.each_with_index.map { |(item, status, note), index| row(index + 1, item, status, note) }
        end

        private

        def row(position, item, status, note)
          fact = @facts.fetch(item.key, {})
          Row.new(position, tier(item, fact), fact[:step], item.key, status, item.area.join(","), note)
        end

        def note(item)
          skip = @plan.skipped.find { |entry| entry.key == item.key }
          skip ? skip.reason.delete_prefix("skipped: ") : "would start"
        end

        def tier(item, fact)
          return RED if red?(item)

          fact[:priority].to_s.empty? ? UNRANKED : fact[:priority].to_s
        end

        def red?(item)
          item.key.start_with?(Dispatching::WorkItems::RED) ||
            (item.key == "push-due" && item.title.start_with?(PushSize::URGENT))
        end

        def facts(registry)
          aggregate = StartedWork.work_aggregate(registry)
          return {} unless aggregate

          registry.repository("Tickets", aggregate).all.to_h { |record| [fact(record, :work).to_s, summary(record)] }
        end

        def summary(record) = { step: fact(record, :step), priority: fact(record, :priority) }

        def fact(record, name) = StartedWork.value(record, name)
      end
    end
  end
end
