# frozen_string_literal: true

require "time"
require "hecks/hecks/adapters/ci_runs/failed_jobs"
require_relative "flake_memo"
require_relative "log_backoff"

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

        # The most of a job's log read for spec files: its end, where rspec lists what failed.
        LOG_CAP_BYTES = 2_000_000

        # A spec file in rspec's list of failed examples (`rspec ./spec/x_spec.rb:12 # ...`). The
        # REST log holds every step, so a command line that merely names a spec file is not one.
        FAILED_EXAMPLE = %r{rspec (?:\./)?(\S+?_spec\.rb):\d+ #}

        private

        def flake_document(limit)
          found = windowed_runs.map { |run| flaked(run) }
          rows = tally(found.compact).first(limit)
          { window_days: WINDOW_DAYS, reaches_back: train_page.map { |run| run["createdAt"] }.compact.min,
            unreadable: found.count(&:nil?), flakes: rows }
        end

        # The passed reruns read for one answer; the memo forgets the attempts of any other run.
        def windowed_runs
          runs = flaked_runs.first(RUN_CAP)
          @attempts.keep(runs.flat_map { |run| attempts_of(run) })
          runs
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
          items = attempts_of(run).flat_map { |key| @attempts.fetch(key) { failed_items(*key) } }
          { branch: run["headBranch"], url: run["url"], items: items.uniq }
        rescue PipelineBoard::Unavailable
          nil
        end

        # The earlier attempts of a passed rerun, each as its run id and attempt number.
        def attempts_of(run) = (1...run["attempt"].to_i).map { |attempt| [run["databaseId"], attempt] }

        # An attempt's job list is read straight from `gh`, not through the cache, so its read
        # holds no lock the other GitHub readers wait on; {FlakeMemo} keeps what it found.
        def failed_items(id, attempt)
          jobs = @gh.call("run", "view", id.to_s, "--attempt", attempt.to_s, "--json", "jobs")["jobs"] || []
          jobs.select { |job| failed?(job) }.flat_map { |job| job_items(id, attempt, job) }
        end

        def job_items(id, attempt, job)
          log = log_of(id, attempt, job["databaseId"])
          files = log.scan(FAILED_EXAMPLE).flatten.uniq
          files.empty? ? [{ item: step_name(job), kind: "setup" }] : files.map { |file| { item: file, kind: "spec" } }
        end

        def step_name(job)
          bad = Array(job["steps"]).reject { |step| Hecks::CheckConclusion.clean?(step["conclusion"]) }
          bad.empty? ? job["name"] : "#{job["name"]}/#{bad.first["name"]}"
        end

        # A job's log, read over REST and cut to its last {LOG_CAP_BYTES}. A read that failed lately
        # is not asked again until its back-off ends: it raises as the failed read did, so the run
        # counts as unread and is read again later.
        def log_of(_id, _attempt, job)
          raise PipelineBoard::Unavailable, "log of job #{job} failed lately; not asked again yet" if @backoff.held?(job)

          text = @text.call("api", "repos/{owner}/{repo}/actions/jobs/#{job}/logs").to_s
          @backoff.clear!(job)
          text.byteslice(-LOG_CAP_BYTES..) || text
        rescue PipelineBoard::Unavailable
          @backoff.failed!(job) unless @backoff.held?(job)
          raise
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
