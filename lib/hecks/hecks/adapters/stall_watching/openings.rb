# frozen_string_literal: true

module Hecks
  module Adapters
    class StallWatching
      # The opening lines of one `StallKind` row that no closing line has closed, read as the row's
      # `closed_by` says. The adapter only interprets the row; the row decides. A closing line
      # closes only the opening lines before it, so an id that opens again after a close stands
      # open from its reopening line.
      #
      # - `id` (or none): a closing line closes the opening lines of the same aggregate id.
      # - `any`: a closing line on the kind's aggregate closes every opening line before it,
      #   whatever its id, as for the machine's load, whose rise and fall are keyed by the beats
      #   that heard them. The subject is the first opening line after the last closing one.
      #
      # A row's `only_about` prefix limits which opening lines count; closing lines of any id close.
      class Openings
        # @param kind [Hash] a `StallKind` row
        # @param lines [Array<Hash>] tap lines in sequence order; the order is read, never re-sorted
        def initialize(kind, lines)
          @kind = kind
          @mine = lines.select { |line| line["kind"] == "event" && line["aggregate"] == kind[:aggregate] }
          @closes = kind[:closes].to_s.split(",").map(&:strip)
        end

        # @return [Hash{String => String}] each open subject with when it opened after its last
        #   close
        def unclosed
          standing.transform_values { |line| line["at"] }.reject { |subject, _| subject.empty? }
        end

        # @param subject [String] an opening line's aggregate id
        # @return [String, nil] the branch the subject's standing opening line links, none when it
        #   links none or the subject stands closed
        def branch(subject)
          standing[subject]&.dig("links", "branch")
        end

        private

        # Each open subject with the opening line it stands open from.
        def standing
          @standing ||= @kind[:closed_by] == "any" ? since_last_close : by_id
        end

        # Read in order: a closing line drops its id's opening, an opening line stands if none does.
        def by_id
          @mine.each_with_object({}) do |line, open|
            id = line["id"].to_s
            if closing?(line) then open.delete(id)
            elsif opening?(line) then open[id] ||= line
            end
          end
        end

        def since_last_close
          last = @mine.rindex { |line| closing?(line) }
          tail = last ? @mine.drop(last + 1) : @mine
          tail.select { |line| opening?(line) }.first(1).to_h { |line| [line["id"].to_s, line] }
        end

        def closing?(line) = @closes.include?(line["event"])

        def opening?(line)
          line["event"] == @kind[:opens] && line["id"].to_s.start_with?(@kind[:only_about].to_s)
        end
      end
    end
  end
end
