# frozen_string_literal: true

require "json"
require_relative "pipeline_turns/block"

module Hecks
  module Adapters
    module PipelineBoard
      # The board's reading of `TurnFinished`: the run cards and the stuck list are projections
      # of the turns the event log holds, so no second source says what a run last said or what
      # is stuck. A run's card is its newest turn; the stuck list is every run's newest turn's
      # stuck rows.
      module Turns
        EVENT = "TurnFinished"

        module_function

        # @param rows [Array<Hash>] journal or tap rows, any order
        # @return [Array<Hash>] the finished turns (string keys) with a payload, oldest first
        def finished(rows)
          rows.select { |row| row[:name].to_s.split(".").last == EVENT && row[:payload].is_a?(Hash) }
              .sort_by { |row| row[:at].to_s }.map { |row| turn(row) }
        end

        # @param turns [Array<Hash>] from `finished`
        # @return [Array<Hash>] one card per run, newest turn first: run, role, session, at and
        #   `last_word`, the turn's verdict
        def run_cards(turns)
          newest(turns).sort_by { |t| t["at"].to_s }.reverse.map do |t|
            { run: t["run"], role: t["role"], session: t["session"], at: t["at"], last_word: t["verdict"] }
          end
        end

        # @param turns [Array<Hash>] from `finished`
        # @return [Array<Hash>] the stuck items of each run's newest turn, oldest `since` first
        def stuck(turns)
          items = newest(turns).flat_map { |t| Array(t["stuck"]).map { |s| s.transform_keys(&:to_s) } }
          items.uniq { |s| [s["kind"], s["what"], s["owner_run"]] }.sort_by { |s| s["since"].to_s }
        end

        # @param turns [Array<Hash>] from `finished`
        # @param run [String, nil] a run key, or nil for the newest turn of any run
        # @return [String] the console block, or an empty string when there is no such turn
        def block(turns, run = nil)
          found = run.to_s.empty? ? turns.last : turns.reverse.find { |t| t["run"] == run }
          found ? Block.render(found) : ""
        end

        def newest(turns) = turns.group_by { |t| t["run"] }.values.map(&:last)

        def turn(row)
          { "run" => row[:id], "at" => row[:at] }.merge(row[:payload].transform_keys(&:to_s))
        end
      end
    end
  end
end
