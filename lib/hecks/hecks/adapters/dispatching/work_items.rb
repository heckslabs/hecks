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

        # The priority tiers a planned work item ranks by, highest first; none ranks last.
        TIERS = %w[now next later].freeze

        # @return [Array<Plan::Item>] the planned work items: a red one first, then by priority
        #   (`now`, `next`, `later`, none), then in plan order (lowest step first, no step last,
        #   ties by key)
        def planned
          having("planned").sort_by.with_index { |entry, index| order(entry, index) }.map(&:last)
        end

        # @return [Array<Plan::Item>] the started work items
        def started = having("started").map(&:last)

        # @return [Array<Hash>] every lesson the Tickets store holds, as {LessonTraps} reads it
        def lessons
          aggregate = find("Tickets", "Lesson")
          return [] unless aggregate

          @registry.repository("Tickets", aggregate).all.map { |record| lesson(record) }
        end

        # @return [Array<String>, nil] the roles the Agents bluebook's `PinnedRole` rows name, or
        #   nil when that bluebook is not loaded
        def pinned_roles
          rows = find("Agents", "Role")&.value_objects&.find { |object| object.hecks_name == "PinnedRole" }
          rows&.members&.map { |row| row[:role].to_s }
        end

        # @return [Hash{String => Hash}] each agent run's key with its `status:` and `condition:`
        def runs
          aggregate = find("Hecks", "AgentRun")
          return {} unless aggregate

          @registry.repository("Hecks", aggregate).all.to_h { |run| [field(run, :run).to_s, state(run)] }
        end

        # @return [Hash{String => String}] each agent run's session id with the run's key, for the
        #   runs that started a session
        def run_sessions
          aggregate = find("Hecks", "AgentRun")
          return {} unless aggregate

          runs = @registry.repository("Hecks", aggregate).all
          runs.to_h { |run| [field(run, :session).to_s, field(run, :run).to_s] }.reject { |session, _| session.empty? }
        end

        private

        def order(entry, index)
          step, rank, item = entry
          [red?(item) ? 0 : 1, rank, step, item.key, index]
        end

        def rank(record) = TIERS.index(field(record, :priority).to_s) || TIERS.size

        def red?(item) = item.key.start_with?(RED) || (item.key == "push-due" && item.title.start_with?(PushSize::URGENT))

        def having(status)
          work = find("Tickets", "Work")
          return [] unless work

          records = @registry.repository("Tickets", work).all
          records.select { |record| field(record, :status) == status }.map { |record| [step(record), rank(record), item(record)] }
        end

        def item(record)
          Plan::Item.new(key: field(record, :work).to_s, title: field(record, :title).to_s,
                         detail: field(record, :detail).to_s, area: StartedWork.words(field(record, :area)),
                         yield_kind: field(record, :yield_kind).to_s, retry_at: field(record, :retry_at).to_s,
                         yield_count: field(record, :yield_count).to_i)
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
