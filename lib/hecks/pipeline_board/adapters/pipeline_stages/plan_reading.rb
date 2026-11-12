# frozen_string_literal: true

require "time"

module Hecks
  module Adapters
    module PipelineBoard
      # What the planning page shows, worked out from the readings the board already holds: the
      # undone Work items, the epics with their finished counts, the sessions, the plan reviews, the
      # fill's dry run and the train. It reads nothing itself and decides nothing the domain
      # decides: an item's epic, priority and area are the ones the Work item declares.
      module PlanReading
        LIVE = %w[busy blocked].freeze
        UNSET = "unset"
        NO_AREA = "no area"

        module_function

        # @param now [Time] the time the ages are measured against
        # @param held [Hash] `items` (the undone Work items: slug, title, status, area,
        #   priority, epic, yield_count, reason, budget_minutes, step), `epics` (epic, title,
        #   outcome, tier, done, dropped), `sessions` (the board's sessions), `reviews` (plan
        #   reviews, oldest first: work, verdict, findings), `fill` (the dry run: would_start,
        #   skipped) and `train` (the strip row)
        # @return [Hash] `strip`, `epics` (open ones first) and `no_epic`
        def build(now:, **held)
          rows = held[:items].map { |item| row(item, held, now) }
          { strip: strip(rows, held), epics: epics_of(held[:epics], rows), no_epic: grouped(rows.select { |r| r[:epic].empty? }) }
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
            owner: held[:sessions].select { |s| OwnerQueue.waiting?(s) } }
        end

        def epics_of(epics, rows)
          epics.map { |epic| epic_of(epic, rows.select { |r| r[:epic] == epic[:epic].to_s }) }
               .sort_by { |epic| [epic[:open].zero? ? 1 : 0, epic[:title].to_s] }
        end

        def epic_of(epic, members)
          epic.merge(open: members.size, running: members.select { |r| r[:session] },
                     next: members.select { |r| r[:status] == "planned" }.min_by { |r| r[:step].to_i }).merge(grouped(members))
        end

        def grouped(members)
          by_area = members.group_by { |r| area_of(r) }.sort_by { |area, _| [area == NO_AREA ? 1 : 0, area] }
          { count: members.size, groups: by_area }
        end

        def area_of(row) = Array(row[:area]).empty? ? NO_AREA : Array(row[:area]).join(", ")
      end
    end
  end
end
