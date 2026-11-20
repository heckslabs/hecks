# frozen_string_literal: true

module Hecks
  module Adapters
    class StallWatching
      # The calls for help the tap shows raised and not closed since, whose impediment is not
      # among the impediments a look holds. It compares keys only: a call's key is `help-` and
      # its impediment's key, and no kind of impediment is read differently from another.
      class Relieved
        AGGREGATE = "Hecks::HelpWanted"
        RAISED = "HelpWantedRaised"
        CLOSED = "HelpWantedClosed"
        REASON = "its impediment left the view"

        # @param lines [Array<Hash>] tap lines in sequence order
        # @param impediments [Array<Hash>] the impediments of the same look, each with its
        #   `impediment` key
        def initialize(lines, impediments)
          @lines = lines.select { |line| line["kind"] == "event" && line["aggregate"] == AGGREGATE }
          @held = impediments.to_set { |row| "help-#{row[:impediment]}" }
        end

        # @param run [String] the look that asks, each row's `id`
        # @return [Array<Hash>] one `Relieved` row per open call whose impediment is gone
        def rows(run)
          (open - @held).sort.map { |help| { id: run, help: help, reason: REASON } }
        end

        private

        # The calls standing open: raised, and not closed since their last raise.
        def open
          @lines.each_with_object(Set.new) do |line, open|
            case line["event"]
            when RAISED then open << line["id"].to_s
            when CLOSED then open.delete(line["id"].to_s)
            end
          end
        end
      end
    end
  end
end
