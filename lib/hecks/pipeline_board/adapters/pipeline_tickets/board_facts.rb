# frozen_string_literal: true

require "json"
require "time"

module Hecks
  module Adapters
    module PipelineBoard
      # The facts the board's `Signal`, `RedEpisodes`, `Measures`, `Epics` and `Holds` readings ask
      # of the aggregates that own them: `RedEpisode.Recent`, the `Epic` measure and outcome
      # documents and `BoardingHold.Status`. It only reads. Mixed into {PipelineTickets}.
      module BoardFacts
        # @param limit [Integer] how many episodes
        # @return [Array<Hash>] `began`, `minutes`, `culprit`, `work` and `ending` of each
        #   episode, newest first
        def recent_red_episodes(limit)
          store.asked("Hecks", "RedEpisode", "Recent").first(limit).map { |record| episode(record) }
        end

        # @return [Array<Hash>] `name`, `value`, `outcome` and `note` of each outcome measure
        def measures
          rows = json(Hecks::Adapters::MeasureReadings.new(registry: @registry).measures)
          rows.map { |row| { name: row["measure"], value: row["reading"], outcome: row["state"], note: bounds(row) } }
        end

        # @return [Array<Hash>] `name`, `value`, `outcome` and `note` of each ranked epic
        def epic_outcomes
          rows = json(Hecks::Adapters::EpicOutcomes.new(registry: @registry).outcomes)
          rows.map { |row| { name: row["epic"], value: members(row), outcome: row["measured"], note: row["measure"].to_s } }
        end

        # @return [Array<Hash>] one row for the hold on local main, `name`, `value` and `note`
        def boarding_hold
          held = store.asked("Hecks", "BoardingHold", "Status")
          held.map { |row| { name: "local main", value: field(row, :text).to_s, note: field(row, :text).to_s } }
        end

        private

        def episode(record)
          began = field(record, :began_at).to_i
          { began: Time.at(began).utc.strftime("%H:%M"), minutes: minutes(began, field(record, :ended_at).to_i),
            culprit: field(record, :culprit).to_s[0, 8], work: field(record, :work).to_s, ending: field(record, :ending).to_s }
        end

        # @return [Integer] minutes from `began` to `ended`, or to now while it stands (ended 0)
        def minutes(began, ended) = ((ended.zero? ? Time.now.to_i : ended) - began) / 60

        def json(answer) = JSON.parse(answer.fetch(:text))

        def members(row) = "#{row.dig("members", "done")}/#{row.dig("members", "all")}"

        def bounds(row) = "at least #{row["at_least"]}, at most #{row["at_most"]}, #{row["span"]}"
      end
    end
  end
end
