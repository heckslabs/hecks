# frozen_string_literal: true

require_relative "relieved"
require_relative "clearing"

module Hecks
  module Adapters
    class StallWatching
      # The impediments a call for help clears that nobody has met: no call for them stands, and no
      # run was ever started under their key. The scrum master's wake reads them, so a wake that
      # failed is not repeated on every beat. It compares keys: a call's key is `help-` and its
      # impediment's key.
      class Unraised
        # The aggregate whose requests start a run, and the event that records one.
        RUNS = "Hecks::AgentRun"
        REQUESTED = "AgentRunRequested"

        # @param lines [Array<Hash>] tap lines in sequence order
        # @param impediments [Array<Hash>] the impediments of the same look
        def initialize(lines, impediments)
          @impediments = impediments
          @calls = Relieved.new(lines, impediments).standing
          @woken = lines.select { |line| line["aggregate"] == RUNS && line["event"] == REQUESTED }
                        .to_set { |line| line["id"].to_s }
        end

        # @param run [String] the look that asks, each row's `id`
        # @return [Array<Hash>] one `Sighting` row per impediment help clears that nothing has met
        def rows(run)
          @impediments.select { |row| new?(row) }.map { |row| row.merge(id: run) }
        end

        private

        def new?(row)
          row[:cleared_by] == Clearing::HELP && !@calls.include?("help-#{row[:impediment]}") &&
            !@woken.include?(row[:impediment])
        end
      end
    end
  end
end
