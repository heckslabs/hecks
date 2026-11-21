# frozen_string_literal: true

require_relative "clearing"

module Hecks
  module Adapters
    class StallWatching
      # The calls for help the tap shows raised and not closed since, which a look does not
      # hold: their impediment is not among the impediments, or it is one its stall item clears,
      # so no stall keeps both a stall item and a call. It compares keys: a call's key is `help-`
      # and its impediment's key.
      class Relieved
        AGGREGATE = "Hecks::HelpWanted"
        RAISED = "HelpWantedRaised"
        CLOSED = "HelpWantedClosed"
        REASON = "its impediment left the view"
        ITEM_REASON = "its stall item clears it"

        # @param lines [Array<Hash>] tap lines in sequence order
        # @param impediments [Array<Hash>] the impediments of the same look, each with its
        #   `impediment` key and its row's `cleared_by`
        def initialize(lines, impediments)
          @lines = lines.select { |line| line["kind"] == "event" && line["aggregate"] == AGGREGATE }
          @clearing = impediments.to_h { |row| ["help-#{row[:impediment]}", row[:cleared_by]] }
        end

        # @param run [String] the look that asks, each row's `id`
        # @return [Array<Hash>] one `Relieved` row per open call whose impediment is gone or is
        #   cleared by its stall item, with which as its reason
        def rows(run)
          standing.sort.filter_map do |help|
            reason = reason(help)
            { id: run, help: help, reason: reason } if reason
          end
        end

        # @return [Set<String>] the keys of the calls standing open: raised, and not closed since
        #   their last raise
        def standing
          @lines.each_with_object(Set.new) do |line, open|
            case line["event"]
            when RAISED then open << line["id"].to_s
            when CLOSED then open.delete(line["id"].to_s)
            end
          end
        end

        private

        # Why a look does not hold the call; nil while its impediment stands and help clears it.
        def reason(help)
          return REASON unless @clearing.key?(help)

          ITEM_REASON unless @clearing[help] == Clearing::HELP
        end
      end
    end
  end
end
