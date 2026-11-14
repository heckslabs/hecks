# frozen_string_literal: true

require_relative "../started_work"
require_relative "plan"
require_relative "epic_tiers"
require_relative "reap_facts"
require_relative "landing_facts"
require_relative "../push_size"

module Hecks
  module Adapters
    class Dispatching
      # The Work items and agent runs of a booted registry, read and never written.
      class WorkItems
        include ReapFacts
        include LandingFacts

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

        # @param item [Plan::Item] a work item
        # @return [Boolean] whether it says main is red: a `red-` key, or the `push-due` work item
        #   once its title says the push is urgent
        def self.red?(item)
          item.key.start_with?(RED) || (item.key == "push-due" && item.title.start_with?(PushSize::URGENT))
        end

        # @return [Array<Plan::Item>] the planned work items: a red one first, then a filed stall,
        #   then by the tier of the work item's epic (1 to 9, lowest first, none last), then by
        #   priority (`now`, `next`, `later`, none), then in plan order (lowest step first,
        #   no step last, ties by key)
        def planned
          stalls = stall_prefixes
          having("planned").sort_by.with_index { |entry, index| order(entry, index, stalls) }.map(&:last)
        end

        # @return [Array<Plan::Item>] the planned work items a roll may start, in the same order: a
        #   red one, a filed stall, or one the owner marked by giving it a priority. An unmarked
        #   item waits for a manual fill.
        def rollable
          stalls = stall_prefixes
          planned.select { |item| rolls?(item, stalls) }
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

        # @return [Array<Hash>] every plan review, in the order recorded, as `run:`, `work:`,
        #   `verdict:` and `findings:`
        def reviews
          aggregate = find("Agents", "PlanReview")
          return [] unless aggregate

          @registry.repository("Agents", aggregate).all.map do |review|
            { run: field(review, :run).to_s, work: field(review, :work).to_s,
              verdict: field(review, :verdict).to_s, findings: field(review, :findings).to_s }
          end
        end

        # @return [Hash{String => Hash}] each agent run's key with its `status:` and `condition:`
        def runs
          aggregate = find("Hecks", "AgentRun")
          return {} unless aggregate

          holders_last(@registry.repository("Hecks", aggregate).all).to_h { |run| [field(run, :run).to_s, state(run)] }
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

        def order(entry, index, stalls)
          step, rank, item = entry
          [urgency(item, stalls), rank, step, item.key, index]
        end

        # Red first, then a stall the StallWatch filed, then the rest.
        def urgency(item, stalls)
          return 0 if red?(item)

          stalls.any? { |prefix| item.key.start_with?(prefix) } ? 1 : 2
        end

        # The key prefix of each kind of stall the StallWatch bluebook's `StallKind` rows declare,
        # `stall-<kind>-`, so a planned work item merely named `stall-...` ranks as any other.
        def stall_prefixes
          rows = find("Hecks", "StallWatch")&.value_objects&.find { |object| object.hecks_name == "StallKind" }
          Array(rows&.members).map { |row| "stall-#{row[:kind]}-" }
        end

        def rank(record, tiers)
          [tiers.fetch(field(record, :epic).to_s, EpicTiers::UNRANKED), TIERS.index(field(record, :priority).to_s) || TIERS.size]
        end

        def red?(item) = self.class.red?(item)

        def rolls?(item, stalls) = urgency(item, stalls) < 2 || TIERS.include?(item.priority)

        def having(status)
          work = find("Tickets", "Work")
          return [] unless work

          records = @registry.repository("Tickets", work).all
          tiers = EpicTiers.of(@registry)
          records = records.select { |record| field(record, :status) == status }
          records.map { |record| [step(record), rank(record, tiers), item(record)] }
        end

        def item(record)
          Plan::Item.new(key: field(record, :work).to_s, title: field(record, :title).to_s,
                         detail: field(record, :detail).to_s, area: StartedWork.words(field(record, :area)),
                         priority: field(record, :priority).to_s, epic: field(record, :epic).to_s,
                         **yielded(record))
        end

        def yielded(record)
          { yield_kind: field(record, :yield_kind).to_s, retry_at: field(record, :retry_at).to_s,
            yield_count: field(record, :yield_count).to_i }
        end

        # A run key reused after its run ended keeps the ended record under another id with the
        # same `run`, and the store lists the records in no set order. The record whose id is its
        # run key holds the key, so it is placed last and its state is the one the key answers; an
        # archive is read only when no record holds its key.
        def holders_last(runs) = runs.sort_by.with_index { |run, index| [holder?(run) ? 1 : 0, index] }

        def holder?(run) = run.id.to_s == field(run, :run).to_s

        def state(run)
          { status: field(run, :status).to_s, condition: field(run, :condition).to_s, started_at: field(run, :started_at).to_s,
                   session: field(run, :session).to_s }
        end

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
