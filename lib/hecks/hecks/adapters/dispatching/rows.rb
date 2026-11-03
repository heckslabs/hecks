# frozen_string_literal: true

require_relative "../started_work"
require_relative "plan"
require_relative "../push_size"

module Hecks
  module Adapters
    class Dispatching
      # The Work rows and agent runs of a booted registry, read and never written.
      class Rows
        # @param registry [Runtime::Registry, nil]
        def initialize(registry)
          @registry = registry
        end

        # The key prefix of a row that says main is red; such a row is planned first, and so is the
        # `push-due` row once its title says the push is urgent.
        RED = "red-"

        # @return [Array<Plan::Row>] the planned rows, red ones first, then in plan order (a row
        #   with no step last)
        def planned = rows("planned").sort_by.with_index { |row, index| [red?(row[1]) ? 0 : 1, row[0], index] }.map(&:last)

        # @return [Array<Plan::Row>] the started rows
        def started = rows("started").map(&:last)

        # @return [Array<Hash>] every lesson the Tickets store holds, as {LessonTraps} reads it
        def lessons
          aggregate = find("Tickets", "Lesson")
          return [] unless aggregate

          @registry.repository("Tickets", aggregate).all.map { |record| lesson(record) }
        end

        # @return [Hash{String => Hash}] each agent run's key with its `status:` and `condition:`
        def runs
          aggregate = find("Hecks", "AgentRun")
          return {} unless aggregate

          @registry.repository("Hecks", aggregate).all.to_h { |run| [field(run, :run).to_s, state(run)] }
        end

        private

        def red?(row) = row.key.start_with?(RED) || (row.key == "push-due" && row.title.start_with?(PushSize::URGENT))

        def rows(status)
          work = find("Tickets", "Work")
          return [] unless work

          records = @registry.repository("Tickets", work).all
          records.select { |record| field(record, :status) == status }.map { |record| [step(record), row(record)] }
        end

        def row(record)
          Plan::Row.new(key: field(record, :work).to_s, title: field(record, :title).to_s,
                        detail: field(record, :detail).to_s, area: StartedWork.words(field(record, :area)))
        end

        def state(run) = { status: field(run, :status).to_s, condition: field(run, :condition).to_s }

        def lesson(record)
          { kind: field(record, :kind).to_s, signature: StartedWork.words(field(record, :signature)),
            cause: field(record, :cause).to_s, check: field(record, :check).to_s, fix: field(record, :fix).to_s,
            always: field(record, :always).to_s, area: StartedWork.words(field(record, :area)) }
        end

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
