# frozen_string_literal: true

module Hecks
  module Adapters
    class StallWatching
      # What the event tap says a row's subject was started for, matched by the row's own
      # attributes; the row decides what follows. A subject's own lines are the lines of the row's
      # aggregate on its id, and the `work` they link names what it was started for.
      #
      # - `answers_aggregate` and `answers_by`: a subject whose own line links a `work` that an
      #   earlier `answers_by` line on `answers_aggregate` names was started to answer that
      #   question. Its block is never filed, so a helper's block starts no helper.
      # - `named_aggregate`: a subject is named when its own line links a `work`, or a line on
      #   `named_aggregate` carries its id; an unnamed one is labelled so in its detail.
      class RunNames
        # @param lines [Array<Hash>] tap lines in sequence order
        def initialize(lines)
          @lines = lines.select { |line| line["kind"] == "event" }
        end

        # @param kind [Hash] a `StallKind` row
        # @param subject [String] an opening line's aggregate id
        # @return [Boolean] whether the subject was started to answer a question the row names
        def answerer?(kind, subject)
          return false if kind[:answers_aggregate].to_s.empty?

          asked = Set.new
          @lines.any? do |line|
            asked << line["id"].to_s if answering?(kind, line)
            own?(kind, line, subject) && asked.include?(work(line))
          end
        end

        # @param kind [Hash] a `StallKind` row
        # @param subject [String] an opening line's aggregate id
        # @return [Boolean] whether the row names an item aggregate and the tap ties the subject
        #   to no item: no own line links a `work` and no item line carries its id
        def unnamed?(kind, subject)
          named = kind[:named_aggregate].to_s
          return false if named.empty?

          @lines.none? do |line|
            (own?(kind, line, subject) && !work(line).empty?) ||
              (line["aggregate"] == named && line["id"].to_s == subject)
          end
        end

        private

        def answering?(kind, line)
          line["aggregate"] == kind[:answers_aggregate] && line["event"] == kind[:answers_by]
        end

        def own?(kind, line, subject) = line["aggregate"] == kind[:aggregate] && line["id"].to_s == subject

        def work(line) = line.dig("links", "work").to_s
      end
    end
  end
end
