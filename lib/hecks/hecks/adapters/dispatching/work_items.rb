# frozen_string_literal: true

require_relative "../started_work"
require_relative "plan"
require_relative "epic_tiers"
require_relative "reap_facts"
require_relative "landing_facts"
require_relative "shed_facts"
require_relative "plan_order"
require_relative "../push_size"

module Hecks
  module Adapters
    class Dispatching
      # The Work items and agent runs of a booted registry, read and never written.
      class WorkItems
        include ReapFacts
        include LandingFacts
        include ShedFacts
        include PlanOrder

        # @param registry [Runtime::Registry, nil]
        def initialize(registry)
          @registry = registry
        end

        # The key prefix of a work item that says main is red; such a work item is planned first,
        # and so is the
        # `push-due` work item once its title says the push is urgent.
        RED = "red-"

        # The priorities a planned work item ranks by, highest first; none ranks last. Priority
        # ranks ahead of the epic's tier, which orders only items of the same priority. It is the
        # Tickets bluebook's `Priority` list, in the same order.
        TIERS = %w[expedite now next later].freeze

        # The priority `Work.expedite!` sets: the lane outside the cap (ADR 0224).
        EXPEDITE = "expedite"

        # @param item [Plan::Item] a work item
        # @return [Boolean] whether it says main is red: a `red-` key, or the `push-due` work item
        #   once its title says the push is urgent
        def self.red?(item)
          item.key.start_with?(RED) || (item.key == "push-due" && item.title.start_with?(PushSize::URGENT))
        end

        # @param item [Plan::Item] a work item
        # @return [Boolean] whether it is expedited and not red: priority `expedite`, which takes
        #   the one place outside the cap; a red one keeps the red rules
        def self.expedited?(item) = !red?(item) && item.priority.to_s == EXPEDITE

        # @param item [Plan::Item] a work item
        # @return [Boolean] whether it is red or expedited, so the boot budget and the epic limit
        #   do not hold it
        def self.urgent?(item) = red?(item) || expedited?(item)

        # @param item [Plan::Item] a work item
        # @return [String] the tier Signalbox admits it at: `urgent` for a red, expedited or
        #   priority-`now` item, which may start in every band and need not leave the gap; else
        #   `normal`
        def self.tier(item) = urgent?(item) || item.priority.to_s == "now" ? "urgent" : "normal"

        # @return [Array<Plan::Item>] the planned work items: a red one first, then an expedited
        #   one, then one whose last
        #   yield a fill restarts first (a `load` yield, by priority alone), then one of priority
        #   `now` that is not a filed stall, then a filed stall, then by the tier of the work item's
        #   epic (1 to 9, lowest first, none last), then by priority (`now`, `next`, `later`,
        #   none), then in plan order (lowest step first, no step last, ties by key)
        def planned
          stalls = urgent_marks
          having("planned").sort_by.with_index { |entry, index| order(entry, index, stalls) }.map(&:last)
        end

        # @return [Array<Plan::Item>] the planned work items a roll may start, in the same order: a
        #   red one, one a `load` yield sent back, a priority-now one, a filed stall, or one the
        #   owner marked by giving it a priority. An unmarked item waits for a manual fill.
        def rollable
          stalls = urgent_marks
          planned.select { |item| rolls?(item, stalls) }
        end

        # @return [Array<Plan::Item>] the started work items, each carrying as `batched` the work
        #   items waiting in its batch
        def started
          members = batched.group_by(&:batch)
          having("started").map { |entry| Plan::Item.new(**entry.last.to_h, batched: members.fetch(entry.last.key, [])) }
        end

        # @return [Array<Plan::Item>] the work items waiting in a batch, each naming its batch
        def batched = having("batched").map(&:last)

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

        # The priority first, then the epic's tier, so the tier orders only items of one priority.
        def rank(record, tiers)
          [TIERS.index(field(record, :priority).to_s) || TIERS.size, tiers.fetch(field(record, :epic).to_s, EpicTiers::UNRANKED)]
        end

        def red?(item) = self.class.red?(item)

        def expedited?(item) = self.class.expedited?(item)

        def rolls?(item, stalls) = urgency(item, stalls) <= STALLED || TIERS.include?(item.priority)

        def having(status)
          work = find("Tickets", "Work")
          return [] unless work

          records = @registry.repository("Tickets", work).all
          tiers = EpicTiers.of(@registry)
          records = records.select { |record| field(record, :status) == status }
          records.map { |record| [step(record), rank(record, tiers), item(record)] }
        end

        def item(record)
          Plan::Item.new(key: field(record, :work).to_s, title: field(record, :title).to_s, detail: field(record, :detail).to_s,
                         area: StartedWork.words(field(record, :area)), waits_on: StartedWork.words(field(record, :waits_on)),
                         priority: field(record, :priority).to_s, epic: field(record, :epic).to_s,
                         **in_batch(record), **yielded(record))
        end

        def in_batch(record) = { batch: field(record, :batch).to_s, batch_commit: field(record, :batch_commit).to_s }

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
            session: field(run, :session).to_s, **flags(run) }
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
