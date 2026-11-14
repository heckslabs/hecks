# frozen_string_literal: true

require "time"

module Hecks
  module Adapters
    class Standup
      # The work items the event tap shows finished: its `WorkFinished` lines of `Tickets::Work`,
      # each work item once, in the order they finished.
      class Finished
        # The aggregate whose lines are read.
        AGGREGATE = "Tickets::Work"

        # The event that says a work item finished.
        EVENT = "WorkFinished"

        # @param lines [Array<Hash>] tap lines in sequence order
        # @param titles [Hash{String => String}] each work item's title by its key
        def initialize(lines, titles)
          @lines = lines
          @titles = titles
        end

        # @param time [Integer] epoch seconds
        # @return [Array<String>] `key: title` of each work item finished at or after the time
        def since(time)
          keys = mine.select { |line| at(line) >= time }.map { |line| line["id"].to_s }.uniq
          keys.map { |key| [key, @titles[key]].reject { |part| part.to_s.empty? }.join(": ") }
        end

        private

        def mine
          @lines.select { |line| line["kind"] == "event" && line["aggregate"] == AGGREGATE && line["event"] == EVENT }
        end

        def at(line) = Time.parse(line["at"].to_s).to_i
      end
    end
  end
end
