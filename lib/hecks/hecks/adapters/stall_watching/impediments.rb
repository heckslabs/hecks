# frozen_string_literal: true

module Hecks
  module Adapters
    class StallWatching
      # The impediments among the open lines: each still open past its row's minutes and within
      # its window, filed or not, one per subject or one per row whose `folds` is "kind", oldest
      # first. It reads the rows' facts only; the rows decide.
      class Impediments
        # @param open [Array<Hash>] the open lines as {Sightings#open_lines} answers them
        def initialize(open)
          @open = open
        end

        # @return [Array<Hash>] one `Sighting` row per impediment, with how many lines it stands
        #   for as `count`, the one that has waited longest first
        def rows
          groups.map { |group| folded(group) }.sort_by { |row| [row[:opened_at], row[:stall]] }
        end

        private

        # The lines past their minutes and within their window, grouped by what each stands for.
        def groups = due.group_by { |row| row[:folds] == "kind" ? row[:stall_kind] : row[:stall] }.values

        def due = @open.select { |row| row[:waited] >= row[:minutes].to_i && row[:waited] < row[:forgets].to_i }

        # The group's oldest line, standing for the rest, under the key the group keeps.
        def folded(group)
          oldest = group.min_by { |row| row[:opened_at] }
          oldest.except(:folds).merge(count: group.size, impediment: key(oldest))
        end

        # What the row stands for over every look: its stall, or its kind when its row folds.
        def key(row) = row[:folds] == "kind" ? "stall-#{row[:stall_kind]}" : row[:stall]
      end
    end
  end
end
