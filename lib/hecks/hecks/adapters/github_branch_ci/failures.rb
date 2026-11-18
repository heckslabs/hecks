# frozen_string_literal: true

require "hecks/check_conclusion"
require_relative "../console_capture"

module Hecks
  module Adapters
    class GithubBranchCi
      # The failed jobs of one ended run, each with its failed log and the spec examples that log
      # names as failed. A job is failed when the `CheckConclusion` rows do not call its conclusion
      # clean; a log that cannot be read names no example.
      class Failures
        # One failed job: its name, the failed log (nil when unread) and the examples it names.
        Failure = Struct.new(:name, :log, :examples)

        # An example RSpec names as failed, such as `rspec ./spec/a_spec.rb:12`.
        EXAMPLE = %r{rspec (\./spec/\S+)}

        # Jobs read per page: GitHub answers a page of 100 jobs of a rerun run with a 502.
        PAGE = 30

        # @param github [GhCall] the calls to GitHub
        def initialize(github)
          @github = github
        end

        # @param run_id [String] the run's id
        # @return [Array<Failure>] its failed jobs, empty when none failed
        # @raise [ConsoleCapture::Failure] when the run's jobs cannot be read
        def of(run_id)
          failed_jobs(run_id).map do |job|
            log = failed_log(run_id, job)
            Failure.new(job["name"].to_s, log, examples(log))
          end
        end

        private

        def failed_jobs(run_id)
          pages = @github.api("actions/runs/#{run_id}/jobs?per_page=#{PAGE}", "--paginate", "--slurp")
          jobs = Array(pages).flat_map { |page| page.fetch("jobs", []) }
          jobs.reject { |job| Hecks::CheckConclusion.clean?(job["conclusion"]) }
        end

        def failed_log(run_id, job)
          @github.run!(["gh", "run", "view", run_id, "--job", job["id"].to_s, "--log-failed"], "log")
        rescue ConsoleCapture::Failure
          nil
        end

        def examples(log)
          named = log.to_s.scan(EXAMPLE).flatten
          named.uniq
        end
      end
    end
  end
end
