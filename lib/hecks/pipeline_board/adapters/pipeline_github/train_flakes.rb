# frozen_string_literal: true

require "time"
require "hecks/hecks/adapters/ci_runs/failed_jobs"

module Hecks
  module Adapters
    module PipelineBoard
      # What failed on an earlier attempt of a train pull request's CI run that a later attempt of
      # the same run passed. GitHub keeps every attempt of a run, so the reading is durable and
      # needs no record of the board's own. A spec failure is told by its spec file (a shard holds
      # other files from one run to the next and a line moves), a failure before the specs by its
      # job and step. An item counts once per run, however many attempts it failed.
      module TrainFlakes
        # How many days back the flakes reach.
        WINDOW_DAYS = 14

        # How many passed reruns are read for one answer: each costs a job list and a log per
        # earlier attempt.
        RUN_CAP = 20

        private

        def flake_document(limit)
          found = flaked_runs.first(RUN_CAP).map { |run| flaked(run) }
          rows = tally(found.compact).first(limit)
          { window_days: WINDOW_DAYS, reaches_back: train_page.map { |run| run["createdAt"] }.compact.min,
            unreadable: found.count(&:nil?), flakes: rows }
        end

        def flaked_runs
          since = Time.now - (WINDOW_DAYS * 86_400)
          train_page.select { |run| passed_rerun?(run) && Time.parse(run["createdAt"]) >= since }
        end

        def passed_rerun?(run)
          train_branch?(run) && run["attempt"].to_i > 1 && run["conclusion"] == "success"
        end

        def train_branch?(run) = run["headBranch"].to_s.start_with?(TrainRuns::TRAIN_PREFIX)

        # The items one passed rerun cleared, or nil when an earlier attempt could not be read.
        def flaked(run)
          items = (1...run["attempt"].to_i).flat_map { |attempt| failed_items(run["databaseId"], attempt) }
          { branch: run["headBranch"], url: run["url"], items: items.uniq }
        rescue PipelineBoard::Unavailable
          nil
        end

        def failed_items(id, attempt)
          jobs = read("run", "view", id.to_s, "--attempt", attempt.to_s, "--json", "jobs")["jobs"] || []
          jobs.select { |job| failed?(job) }.flat_map { |job| job_items(id, attempt, job) }
        end

        def job_items(id, attempt, job)
          log = log_of(id, attempt, job["databaseId"])
          files = log.scan(CiRuns::FailedJobs::SPEC_LINE).flatten.uniq
          files.empty? ? [{ item: step_name(job), kind: "setup" }] : files.map { |file| { item: file, kind: "spec" } }
        end

        def step_name(job)
          bad = Array(job["steps"]).reject { |step| Hecks::CheckConclusion.clean?(step["conclusion"]) }
          bad.empty? ? job["name"] : "#{job["name"]}/#{bad.first["name"]}"
        end

        def log_of(id, attempt, job)
          args = ["run", "view", id.to_s, "--attempt", attempt.to_s, "--job", job.to_s, "--log-failed"]
          @cache.fetch(args) { @text.call(*args) }.to_s
        end

        def tally(found)
          grouped = found.flat_map { |run| run[:items].map { |item| [item, run] } }.group_by(&:first)
          rows = grouped.map { |item, pairs| flake_row(item, pairs.map(&:last)) }
          rows.sort_by { |row| [-row[:count], row[:item]] }
        end

        def flake_row(item, runs)
          { item: item[:item], kind: item[:kind], count: runs.size,
            prs: runs.map { |run| { branch: run[:branch], url: run[:url] } } }
        end
      end
    end
  end
end
