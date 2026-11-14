# frozen_string_literal: true

module Hecks
  module Adapters
    module PipelineBoard
      # The order the planning page reads in. Every Work item sits in one lane, the most urgent
      # thing true of it: a session is running it, or the priority it declares. An epic sits in the
      # most urgent lane any of its open items is in, so the page leads with what moves now.
      module PlanOrder
        # The lanes, most urgent first. `done` holds only epics with nothing left open.
        LANES = %w[running now next later unset done].freeze
        UNSET = "unset"

        module_function

        # @param row [Hash] a row of {PlanReading}
        # @return [Hash] the row with its `lane`
        def placed(row)
          lane = LANES.include?(row[:priority]) ? row[:priority] : UNSET
          row.merge(lane: row[:session] ? "running" : lane)
        end

        # @param members [Array<Hash>] an epic's open rows
        # @return [String] the most urgent lane among them, or `done` when none is open
        def lane(members)
          return "done" if members.empty?

          LANES.find { |lane| members.any? { |row| row[:lane] == lane } }
        end

        # @param members [Array<Hash>] rows carrying a `lane`
        # @return [Array<Hash>] the rows by lane, then by the step the plan gives them
        def items(members) = members.sort_by { |row| [LANES.index(row[:lane]), row[:step].to_i, row[:slug].to_s] }

        # @param list [Array<Hash>] epics carrying `lane`, `done` and `open`
        # @return [Array<Hash>] the epics by lane, the nearest to finished first inside a lane
        def epics(list) = list.sort_by { |epic| [LANES.index(epic[:lane]), -share(epic), epic[:title].to_s] }

        # @return [Float] the part of an epic's items that are finished, from 0 to 1
        def share(epic)
          total = epic[:done].to_i + epic[:open].to_i
          total.zero? ? 0.0 : epic[:done].to_f / total
        end

        # @param rows [Array<Hash>] every open row
        # @param epics [Array<Hash>] every epic
        # @return [Hash] `done`, `open`, `epics` (those with open items) and `lanes` (items in each)
        def summary(rows, epics)
          done = epics.sum { |epic| epic[:done].to_i }
          lanes = LANES.to_h { |lane| [lane, rows.count { |row| row[:lane] == lane }] }
          { done: done, open: rows.size, epics: epics.count { |epic| epic[:open].positive? }, lanes: lanes.merge("done" => done) }
        end
      end
    end
  end
end
