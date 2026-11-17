# frozen_string_literal: true

require "json"
require "hecks/hecks/adapters/started_work"

module Hecks
  module Adapters
    module PipelineBoard
      # CI as the domain recorded it: the `CiRunRecord` rows the clock's beat notes from GitHub
      # (`lib/hecks/hecks/ci_record/ci_record.bluebook`). Reading them starts no program and asks
      # GitHub nothing, so the board shows CI on a loaded machine, straight after a restart and
      # with the rate budget spent. A run is recorded when it is seen going and again when it is
      # seen done; the newest record of a run is the run. A reader with no record to answer from
      # raises {Unavailable}, so the board says CI is not recorded yet and never asks `gh`.
      module CiRecords
        # The bluebook and the aggregate the records are of.
        RECORD = %w[Hecks CiRunRecord].freeze
        # What a board row says in words and in whole numbers, and the record's field each is read
        # from; and the GitHub event a lane's runs come from.
        WORDS = { sha: :commit, started: :started_at, status: :state, conclusion: :conclusion, pushed: :pushed_at, url: :url,
                  lane: :lane, jobs: :jobs, branch: :branch }.freeze
        COUNTS = { id: :ci_run, failed_jobs: :failed_jobs, attempt: :attempt }.freeze
        EVENT = { "main" => "push", "train" => "pull_request" }.freeze
        # The fields a board row leaves out.
        INTERNAL = %i[lane attempt jobs done branch].freeze

        private

        # @param lane [String] `main` or `train`
        # @param limit [Integer] how many runs
        # @return [Array<Hash>] the newest runs of the lane as board rows, oldest first
        # @raise [PipelineBoard::Unavailable] when no run of the lane is recorded
        def recorded_runs(lane, limit)
          runs = lane_runs(lane)
          raise PipelineBoard::Unavailable, "no #{lane} CI run is recorded yet" if runs.empty?

          runs.last(limit).map { |row| row.except(*INTERNAL) }
        end

        # @param lane [String] `main` or `train`
        # @param limit [Integer] how many jobs
        # @return [Array<Hash>] the slowest jobs of the newest completed run recorded with its jobs
        # @raise [PipelineBoard::Unavailable] when no such run is recorded
        def recorded_slowest(lane, limit)
          done = lane_runs(lane).reverse.find { |row| row[:done] && !row[:jobs].empty? }
          raise PipelineBoard::Unavailable, "no completed #{lane} CI run is recorded with its jobs yet" unless done

          slowest_first(done[:jobs]).first(limit)
        end

        def slowest_first(json)
          JSON.parse(json, symbolize_names: true).sort_by { |job| -job[:minutes].to_f }
        rescue JSON::ParserError
          raise PipelineBoard::Unavailable, "a recorded run's jobs are unreadable"
        end

        # One row per run of the lane, from its newest record, oldest first. The train's runs are
        # their first attempts, as the board lists them: a rerun's wall time is not the run's.
        def lane_runs(lane)
          rows = record_rows.select { |row| row[:lane] == lane }
          rows = rows.select { |row| row[:attempt] == 1 } if lane == "train"
          each_run(rows).sort_by { |row| row[:pushed] }
        end

        # One row per run: the newest of the records that share its id.
        def each_run(rows) = rows.group_by { |row| row[:id] }.values.map { |seen| newest(seen) }

        # The newest record of one run: its latest attempt, done over going.
        def newest(seen) = seen.max_by { |row| [row[:attempt], row[:done] ? 1 : 0] }

        # Every record held, as a row; none when the seats cannot be read.
        def record_rows
          seats = @seats&.call
          seats ? seats.records(*RECORD).map { |record| record_row(record) } : []
        rescue PipelineBoard::Unavailable
          []
        end

        def record_row(record)
          row = WORDS.transform_values { |name| StartedWork.value(record, name).to_s }
          counts = COUNTS.transform_values { |name| StartedWork.value(record, name).to_s.to_i }
          row.merge(counts, sha: row[:sha][0, 7], wall_minutes: StartedWork.value(record, :wall_minutes).to_s.to_f,
                            event: EVENT.fetch(row[:lane], ""), done: row[:status] == "completed")
        end
      end
    end
  end
end
