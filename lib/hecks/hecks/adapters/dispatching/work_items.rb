# frozen_string_literal: true

require_relative "../started_work"
require_relative "plan"
require_relative "../push_size"

module Hecks
  module Adapters
    class Dispatching
      # The Work items and agent runs of a booted registry, read and never written.
      class WorkItems
        # @param registry [Runtime::Registry, nil]
        def initialize(registry)
          @registry = registry
        end

        # The key prefix of a work item that says main is red; such a work item is planned first,
        # and so is the
        # `push-due` work item once its title says the push is urgent.
        RED = "red-"

        # @return [Array<Plan::Item>] the planned work items, red ones first, then in plan order (a
        #   work item
        #   with no step last)
        def planned = having("planned").sort_by.with_index { |item, index| [red?(item[1]) ? 0 : 1, item[0], index] }.map(&:last)

        # @return [Array<Plan::Item>] the started work items
        def started = having("started").map(&:last)

        # @return [Hash{String => Hash}] each agent run's key with its `status:` and `condition:`
        def runs
          aggregate = find("Hecks", "AgentRun")
          return {} unless aggregate

          @registry.repository("Hecks", aggregate).all.to_h { |run| [field(run, :run).to_s, state(run)] }
        end

        private

        def red?(item) = item.key.start_with?(RED) || (item.key == "push-due" && item.title.start_with?(PushSize::URGENT))

        def having(status)
          work = find("Tickets", "Work")
          return [] unless work

          records = @registry.repository("Tickets", work).all
          records.select { |record| field(record, :status) == status }.map { |record| [step(record), item(record)] }
        end

        def item(record)
          Plan::Item.new(key: field(record, :work).to_s, title: field(record, :title).to_s,
                         detail: field(record, :detail).to_s, area: StartedWork.words(field(record, :area)))
        end

        def state(run) = { status: field(run, :status).to_s, condition: field(run, :condition).to_s }

        def step(record) = field(record, :step) || Float::INFINITY

        def find(domain, name)
          bluebook = @registry&.bluebook(domain)
          bluebook&.aggregates&.find { |candidate| candidate.hecks_name == name }
        end

        def field(record, name) = StartedWork.value(record, name)
      end
    end
  end
end
