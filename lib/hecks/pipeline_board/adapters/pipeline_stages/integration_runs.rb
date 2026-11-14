# frozen_string_literal: true

require "time"
require_relative "../rules"
require_relative "../../../hecks/adapters/main_integration/runs"

module Hecks
  module Adapters
    module PipelineBoard
      # The runs of the MainIntegration saga as the board shows them: how many are stored in each
      # stage, how many are being pushed or watched, how many are parked for a person, and the
      # runs listed with the time the event log last recorded an event of each. A stage is the
      # word the saga stored; nothing here says which stage follows which or which is finished,
      # so a run that waits is shown by its stage and its age, and judged by neither.
      module IntegrationRuns
        NAME = "Integration"

        # The journal name of the aggregate whose events carry a run's landed commit.
        AGGREGATE = "Hecks::Integration"

        # The event one advance of the runs is recorded with.
        ADVANCED = "IntegrationAdvanced"

        # The stage of a run parked for a person, the one stage the board tells apart.
        PARKED = "needs_human"

        # The stages in which a run is being pushed or watched, as the Integration adapter has them.
        IN_FLIGHT = MainIntegration::Runs::IN_FLIGHT

        module_function

        # What the event log's tail says of the runs, for display only.
        #
        # @param rows [Array<Hash>] the log's newest events as board rows, oldest first
        # @return [Hash] `times:` each landed commit and the time of its newest Integration event,
        #   `advanced:` the time of the newest advance, `since:` the time the rows reach back to
        def seen(rows)
          own = rows.select { |row| row[:aggregate] == AGGREGATE }
          { times: times_of(own), advanced: at_of(own.reverse.find { |row| row[:name] == ADVANCED }), since: at_of(rows.first) }
        end

        # Each landed commit the events name, with the time of the newest event that names it.
        def times_of(events)
          events.each_with_object({}) do |event, times|
            landed = event[:links].to_h["landed"].to_s
            times[landed] = event[:at] unless landed.empty?
          end
        end

        def at_of(row) = row && row[:at]

        # @param stored [Hash{String => String}] each run's landed commit and its stored stage
        # @param seen [Hash] what {seen} answers; empty when the log could not be read
        # @param now [Time] the time the ages are counted to
        # @return [Hash] `total`, `stages` (a count per stage), `in_flight`, `needs_human`,
        #   `last_advance`, `log_since`, `quiet_minutes` (how far back the log's tail reaches),
        #   `by_stage` and `runs`, at most `integration_runs_shown` of them
        def build(stored, seen, now)
          times = seen[:times].to_h
          runs = stored.map { |landed, stage| run(landed, stage, times[landed], now) }
          listed = { by_stage: by_stage(runs), runs: ordered(runs).first(Rules.setting("integration_runs_shown")) }
          counts(stored.values).merge(logged(seen, now), listed)
        end

        # What the log says of the runs as a whole: the newest advance and how far its tail reaches.
        def logged(seen, now)
          { last_advance: seen[:advanced], log_since: seen[:since], quiet_minutes: minutes_since(seen[:since], now) }
        end

        # One line per stored stage, so a stage whose runs wait shows how long none has moved.
        #
        # @param runs [Array<Hash>] every run
        # @return [Array<Hash>] each stage's `stage`, `count`, `minutes` since the newest event of
        #   any of its runs (nil when the log's tail holds none) and `parked`; the parked stage
        #   comes first
        def by_stage(runs)
          lines = runs.group_by { |run| run[:stage] }.map do |stage, held|
            { stage: stage, count: held.size, minutes: held.filter_map { |run| run[:minutes] }.min, parked: stage == PARKED }
          end
          lines.sort_by { |line| [line[:parked] ? 0 : 1, line[:stage]] }
        end

        # @param stages [Array<String>] the stage stored for each run
        # @return [Hash] `total`, `stages`, `in_flight` and `needs_human`
        def counts(stages)
          { total: stages.size, stages: stages.tally, in_flight: stages.count { |stage| IN_FLIGHT.include?(stage) },
            needs_human: stages.count(PARKED) }
        end

        # @param reading [Hash, nil] what {build} answers, or `{unknown: reason}`
        # @param now [Time] the time the advance's age is counted to
        # @return [Hash] the strip's row: `name`, `state`, `count` and `detail`
        def row(reading, now)
          return unknown(reading) unless reading.is_a?(Hash) && reading.key?(:runs)

          { name: NAME, state: Rules.verdict(NAME, needs_human: reading[:needs_human]), count: reading[:in_flight].to_s,
            detail: detail(reading, now) }
        end

        # @param reading [Hash] what {build} answers
        # @param now [Time]
        # @return [String] the counts, the newest advance and the count per stage, in one line
        def detail(reading, now)
          stages = reading[:stages].map { |stage, count| "#{stage} #{count}" }.join(", ")
          "#{reading[:in_flight]} being pushed or watched, #{reading[:needs_human]} parked for you, " \
            "of #{reading[:total]} runs; last advance " \
            "#{since(minutes_since(reading[:last_advance], now), reading[:quiet_minutes])}; " \
            "stored: #{stages.empty? ? "none" : stages}"
        end

        # @param minutes [Integer, nil] the minutes since an event; nil when the tail holds none
        # @param quiet [Integer, nil] the minutes the log's tail reaches back
        # @return [String] the minutes since the event, or for how long at least there was none
        def since(minutes, quiet)
          return "#{minutes} min ago" if minutes

          quiet.to_i.positive? ? "none for over #{quiet} min" : "none in the log's tail"
        end

        # @param at [String, nil] a recorded time
        # @param now [Time]
        # @return [Integer, nil] whole minutes since it; nil when there is none or it cannot be read
        def minutes_since(at, now)
          at && ((now - Time.parse(at)) / 60).floor
        rescue ArgumentError
          nil
        end

        def run(landed, stage, at, now)
          { landed: landed, short: landed[0, 10], stage: stage, at: at, minutes: minutes_since(at, now), parked: stage == PARKED }
        end

        # The runs the log's tail holds an event of, newest first, then the parked runs, then the
        # rest.
        def ordered(runs)
          runs.sort_by { |run| [run[:minutes] || Float::INFINITY, run[:parked] ? 0 : 1, run[:landed]] }
        end

        def unknown(reading)
          reason = reading.is_a?(Hash) ? reading[:unknown] : "no data"
          { name: NAME, state: "unknown", count: "-", detail: "unknown: #{reason}" }
        end
      end
    end
  end
end
