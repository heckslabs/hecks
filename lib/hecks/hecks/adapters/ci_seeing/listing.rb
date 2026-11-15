# frozen_string_literal: true

require "json"
require "time"

module Hecks
  module Adapters
    class CiSeeing
      # The CI runs GitHub lists now, as the rows a record takes: main's pushes and the pull
      # requests of the push train. `gh run list` cannot filter by a branch's prefix, so a wider
      # page of pull request runs is read and the train's branches kept.
      class Listing
        WORKFLOW = "ci.yml"
        # What a row says in words, and the field of GitHub's run each is read from.
        WORDS = { commit: "headSha", branch: "headBranch", state: "status", conclusion: "conclusion", pushed_at: "createdAt",
                  started_at: "startedAt", updated_at: "updatedAt", url: "url" }.freeze
        FIELDS = "databaseId,attempt,event,#{WORDS.values.join(",")}".freeze
        # How many runs of main, and how wide a page of pull request runs, one look reads.
        MAIN_RUNS = 20
        PULL_PAGE = 100
        # Branch prefix of the push train's pull requests.
        TRAIN_PREFIX = "train/"
        # The conclusions that count a job as failed.
        FAILED = %w[failure timed_out cancelled startup_failure].freeze
        # How many of a run's slowest jobs its record keeps beside the failed ones.
        SLOWEST = 8

        # @param ask [#call] runs `gh` with the given arguments and answers its parsed JSON
        def initialize(ask)
          @ask = ask
        end

        # @return [Array<Hash>] one row per run of main and of a train branch, without its jobs
        def rows
          main = list("--branch", "main", "--limit", MAIN_RUNS.to_s)
          pulls = list("--event", "pull_request", "--limit", PULL_PAGE.to_s)
          train = pulls.select { |run| run["headBranch"].to_s.start_with?(TRAIN_PREFIX) }
          main.map { |run| row(run, "main") } + train.map { |run| row(run, "train") }
        end

        # @param row [Hash] a row of a completed run
        # @return [Hash] the row with `failed_jobs` and `jobs`: its failed jobs and its slowest, as
        #   JSON (`[]` when GitHub lists none, so the record knows they were read)
        def with_jobs(row)
          jobs = jobs_of(row[:ci_run])
          failed = jobs.select { |job| FAILED.include?(job[:conclusion]) }
          slowest = jobs.sort_by { |job| -job[:minutes] }.first(SLOWEST)
          row.merge(failed_jobs: failed.size, jobs: JSON.generate((failed + slowest).uniq))
        end

        private

        def list(*narrowed) = @ask.call("run", "list", "--workflow", WORKFLOW, *narrowed, "--json", FIELDS)

        def jobs_of(run) = Array(@ask.call("run", "view", run, "--json", "jobs")["jobs"]).filter_map { |job| job_row(job) }

        def row(run, lane)
          words = WORDS.transform_values { |field| run[field].to_s }
          words.merge(ci_run: run["databaseId"].to_s, lane: lane, attempt: [run["attempt"].to_i, 1].max,
                      wall_minutes: wall(run), failed_jobs: 0, jobs: "")
        end

        # A run's wall time once it has completed; a run still going has none yet.
        def wall(run) = run["status"] == "completed" ? minutes(run["startedAt"], run["updatedAt"]) : 0.0

        def job_row(job)
          return unless job["startedAt"] && job["completedAt"]

          { name: job["name"].to_s, minutes: minutes(job["startedAt"], job["completedAt"]),
            conclusion: job["conclusion"].to_s, url: job["url"].to_s }
        end

        def minutes(from, upto)
          return 0.0 if from.to_s.empty? || upto.to_s.empty?

          ((Time.parse(upto) - Time.parse(from)) / 60.0).round(1)
        rescue ArgumentError
          0.0
        end
      end
    end
  end
end
