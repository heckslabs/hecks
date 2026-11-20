# frozen_string_literal: true

require "time"
require_relative "plan_order"
require_relative "plan_flow"

module Hecks
  module Adapters
    module PipelineBoard
      # What the planning page shows, worked out from the readings the board already holds: the
      # undone Work items, the epics with their finished counts, the sessions, the plan reviews, the
      # fill's dry run and the train. It reads nothing itself and decides nothing the domain
      # decides: an item's epic, priority and area are the ones the Work item declares, and
      # {PlanOrder} only puts them in reading order.
      module PlanReading
        LIVE = %w[busy blocked].freeze
        UNSET = PlanOrder::UNSET

        module_function

        # @param now [Time] the time the ages are measured against
        # @param held [Hash] `items` (the undone Work items: slug, title, status, area,
        #   priority, epic, yield_count, reason, budget_minutes, step), `epics` (epic, title,
        #   outcome, tier, done, dropped), `sessions` (the board's sessions), `reviews` (plan
        #   reviews, oldest first: work, verdict, findings), `fill` (the dry run: would_start,
        #   skipped), `train` (the strip row), `flow` (when Work items were planned, finished
        #   and dropped; see {PlanFlow.build}) and `help` (the calls for help the owner is shown;
        #   see {HelpQueue.lines})
        # @return [Hash] `strip`, `summary` (see {PlanOrder.summary}), `epics` (most urgent first,
        #   each with its `lane` and ordered `items`), `no_epic` (`count` and `items`) and `flow`
        def build(now:, **held)
          rows = held[:items].map { |item| PlanOrder.placed(row(item, held, now)) }
          epics = epics_of(held[:epics], rows)
          { strip: strip(rows, held), summary: PlanOrder.summary(rows, epics), epics: epics,
            no_epic: listed(rows.select { |r| r[:epic].empty? }), flow: PlanFlow.build(held[:flow], now, rows.size) }
        end

        def row(item, held, now)
          session = session_of(item, held[:sessions])
          item.merge(priority: priority_of(item), epic: item[:epic].to_s, session: session&.fetch(:id, nil),
                     minutes: minutes(session, now), reviewed: held[:reviews].select { |r| r[:work] == item[:slug] })
        end

        def session_of(item, sessions)
          sessions.find { |found| found[:work_item] == item[:slug] && LIVE.include?(found[:status]) }
        end

        def priority_of(item) = item[:priority].to_s.empty? ? UNSET : item[:priority].to_s

        def minutes(session, now)
          started = session && Time.parse(session[:started].to_s)
          started && ((now - started) / 60).round
        rescue ArgumentError
          nil
        end

        def strip(rows, held)
          { running: rows.select { |r| r[:session] }, next: Array(held[:fill][:would_start]),
            held: Array(held[:fill][:skipped]), landing: held[:train],
            owner: OwnerQueue.waiting(held[:sessions]), help: Array(held[:help]) }
        end

        def epics_of(epics, rows)
          PlanOrder.epics(epics.map { |epic| epic_of(epic, rows.select { |r| r[:epic] == epic[:epic].to_s }) })
        end

        def epic_of(epic, members)
          epic.merge(open: members.size, running: members.select { |r| r[:session] }, lane: PlanOrder.lane(members),
                     decisions: decisions_of(epic, members),
                     next: members.select { |r| r[:status] == "planned" }.min_by { |r| r[:step].to_i })
              .merge(listed(members))
        end

        # The decisions an epic carries out: its own, then the ones its items name, each once.
        def decisions_of(epic, members) = ([epic[:decision]] + members.map { |r| r[:decision] }).map(&:to_s).reject(&:empty?).uniq

        def listed(members) = { count: members.size, items: PlanOrder.items(members) }
      end
    end
  end
end
