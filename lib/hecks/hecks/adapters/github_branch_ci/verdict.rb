# frozen_string_literal: true

require "time"
require "hecks/check_conclusion"

module Hecks
  module Adapters
    class GithubBranchCi
      # What one ended run says: the jobs whose conclusion the `CheckConclusion` rows do not call
      # clean, each with the last lines of its failed log, and how long the run queued and took.
      class Verdict
        # The failed log lines a report keeps of each job, from its end.
        LINES = 5

        # @param github [GhCall] the calls to GitHub
        # @param run [Hash] the ended run
        # @param pushed_at [Time] when the branch was pushed
        def initialize(github, run, pushed_at)
          @github = github
          @run = run
          @pushed_at = pushed_at
        end

        # @param sha [String] the head the run checked
        # @param number [String] the draft's number
        # @return [Hash{Symbol => Hash}] the port's answer
        def answer(sha, number)
          failed = failed_jobs
          { sha: { value: sha }, number: { value: number }, ci_run: { value: @run["id"].to_s },
            failing: { value: failed.map { |job| job["name"] }.join(", ") }, report: { value: report(failed) } }
        end

        private

        def failed_jobs
          pages = @github.api("actions/runs/#{@run["id"]}/jobs?per_page=100", "--paginate", "--slurp")
          jobs = Array(pages).flat_map { |page| page.fetch("jobs", []) }
          jobs.reject { |job| Hecks::CheckConclusion.clean?(job["conclusion"]) }
        end

        def report(failed)
          lines = ["CI run #{@run["id"]} (#{@run["html_url"]}): #{@run["conclusion"]}; #{timing}"]
          (lines + failed.map { |job| "#{job["name"]}: #{last_lines(job)}" }).join("\n")
        end

        def timing
          created, started, ended = %w[created_at run_started_at updated_at].map { |key| Time.parse(@run[key].to_s) }
          "queued #{(started - created).round}s, push to end #{((ended - @pushed_at) / 60).round(1)} min"
        rescue ArgumentError
          "times unread"
        end

        def last_lines(job)
          log = @github.run!(["gh", "run", "view", @run["id"].to_s, "--job", job["id"].to_s, "--log-failed"], "log")
          tail(log).join(" | ")
        rescue ConsoleCapture::Failure
          "log unread"
        end

        def tail(log) = log.lines.last(LINES).map(&:strip)
      end
    end
  end
end
