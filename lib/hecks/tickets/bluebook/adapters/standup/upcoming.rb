# frozen_string_literal: true

module Hecks
  module Adapters
    class Standup
      # The planned work items of the priority report, in the order it gives them, each with its
      # title and whether it would start or why it waits. It orders and judges nothing.
      class Upcoming
        # The report's note for a work item a filling would start now.
        STARTS = "would start"

        # @param rows [Array<PriorityReport::Backlog::Row>] every open work item in dispatch order
        # @param titles [Hash{String => String}] each work item's title by its key
        def initialize(rows, titles)
          @rows = rows
          @titles = titles
        end

        # @param count [Integer] how many work items to say
        # @return [Array<String>] one numbered line for each of the first planned work items
        def first(count)
          planned = @rows.select { |row| row.status == "planned" }.first(count)
          planned.each_with_index.map { |row, index| "#{index + 1}. #{row.key}: #{@titles[row.key]} (#{note(row)})" }
        end

        private

        def note(row) = row.note == STARTS ? STARTS : "waits: #{row.note}"
      end
    end
  end
end
