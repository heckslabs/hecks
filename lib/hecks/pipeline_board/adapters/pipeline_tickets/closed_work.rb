# frozen_string_literal: true

module Hecks
  module Adapters
    module PipelineBoard
      # The Work items of an epic that are over: finished or dropped. The planning page counts
      # them on the epic's row and lists them under its open items, so an opened epic shows all
      # the work it holds and not only what is left.
      module ClosedWork
        # The statuses a Work item ends in.
        OVER = %w[done dropped].freeze
        # What a row says of a Work item, and the record's field each is read from.
        FIELDS = { slug: :work, title: :title, status: :status }.freeze

        module_function

        # @param works [Array<Object>] the Work records of one epic
        # @param field [#call] reads a field of a record by name
        # @return [Hash] `done` and `dropped` (how many of each) and `closed`: the slug, title and
        #   status of each, the finished ones first
        def of(works, field)
          rows = works.map { |work| row(work, field) }.select { |row| OVER.include?(row[:status]) }
          tally = rows.map { |row| row[:status] }.tally
          { done: tally.fetch("done", 0), dropped: tally.fetch("dropped", 0),
            closed: rows.sort_by { |row| [OVER.index(row[:status]), row[:title]] } }
        end

        # @return [Hash] a Work record's slug, title and status
        def row(work, field) = FIELDS.transform_values { |name| field.call(work, name).to_s }
      end
    end
  end
end
