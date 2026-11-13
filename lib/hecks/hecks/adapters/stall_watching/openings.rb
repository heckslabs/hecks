# frozen_string_literal: true

module Hecks
  module Adapters
    class StallWatching
      # The opening lines of one `StallKind` row that no closing line has closed, read as the row's
      # `closed_by` says. The adapter only interprets the row; the row decides.
      #
      # - `id` (or none): a closing line closes the opening lines of the same aggregate id.
      # - `any`: a closing line on the kind's aggregate closes every opening line before it,
      #   whatever its id, as for the machine's load, whose rise and fall are keyed by the beats
      #   that heard them. The subject is the first opening line after the last closing one.
      class Openings
        # @param kind [Hash] a `StallKind` row
        # @param lines [Array<Hash>] tap lines in sequence order
        def initialize(kind, lines)
          @kind = kind
          @mine = lines.select { |line| line["kind"] == "event" && line["aggregate"] == kind[:aggregate] }
          @closes = kind[:closes].to_s.split(",").map(&:strip)
        end

        # @return [Hash{String => String}] each open subject with when it first opened
        def unclosed
          open = @kind[:closed_by] == "any" ? since_last_close : by_id
          open.reject { |subject, _| subject.empty? }
        end

        private

        def by_id
          closed = @mine.select { |line| @closes.include?(line["event"]) }.map { |line| line["id"].to_s }
          opened(@mine).except(*closed)
        end

        def since_last_close
          last = @mine.rindex { |line| @closes.include?(line["event"]) }
          opened(last ? @mine.drop(last + 1) : @mine).first(1).to_h
        end

        # The first time each subject recorded the opening event.
        def opened(lines)
          lines.select { |line| line["event"] == @kind[:opens] }
               .each_with_object({}) { |line, first| first[line["id"].to_s] ||= line["at"] }
        end
      end
    end
  end
end
