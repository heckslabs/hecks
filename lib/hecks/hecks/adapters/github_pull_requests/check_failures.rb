# frozen_string_literal: true

require "json"
require_relative "../console_capture"
require_relative "../ci_runs/checks"
require_relative "../ci_runs/failed_jobs"
require_relative "../git_shallow_check/culprit"
require_relative "touching_commit"

module Hecks
  module Adapters
    class GithubPullRequests
      # Why the checks of one pull request failed, as one row per failed job: the job, its failed
      # steps, the failing spec examples its log names, the message of its first failure and the
      # commit it is attributed to. It reads the pull request's checks, the failed jobs of each
      # Actions run a failed check belongs to, and their failed logs, all through `gh`; nothing on
      # GitHub is changed. A job that never reached the specs answers no examples.
      class CheckFailures
        # The Actions run a check's details link belongs to.
        RUN = %r{/actions/runs/(\d+)}

        # What `gh` puts before each log line: the job, the step and a timestamp.
        PREFIX = /\A[^\t]*\t[^\t]*\t﻿?\S+Z ?/

        # What a refusal of `gh` opens with; the reader of the jobs says it again.
        REFUSED = /\Agh \S+ \S+ failed: /

        # @param github [#call] takes the `gh` arguments and answers their stdout; raises on failure
        # @param checkout [String] the directory whose `spec/` maps changed files to specs
        def initialize(github, checkout = Dir.pwd)
          @gh = github
          @checkout = checkout
        end

        # @param number [String] the pull request's number
        # @return [Array<Hash{Symbol => String}>] one `job:`/`steps:`/`examples:`/`error:`/
        #   `culprit:` row per failed job, empty when no check failed
        # @raise [ConsoleCapture::Failure] when the number is not a pull request, or GitHub refuses
        def read(number)
          view = JSON.parse(@gh.call("pr", "view", number, "--json", "statusCheckRollup,commits"))
          commits = TouchingCommit.new(@gh, @checkout, view["commits"])
          jobs = runs(view["statusCheckRollup"]).flat_map { |run| CiRuns::FailedJobs.new(method(:run), @checkout).read(run) }
          jobs.map { |job| row(job, commits) }
        end

        private

        # The ids of the Actions runs the failed checks belong to, each once.
        def runs(rollup)
          failed = CiRuns::Checks.new(rollup).failed
          entries = Array(rollup).select { |entry| failed.include?(entry["name"]) }
          entries.filter_map { |entry| entry["detailsUrl"].to_s[RUN, 1] }.uniq
        end

        # Steps and examples are each joined with a comma and a space.
        def row(job, commits)
          { job: job.name.to_s, steps: job.steps.join(", "), examples: job.examples.join(", "),
            error: GitShallowCheck::Culprit.new(plain(job.log)).reason, culprit: commits.name(job.specs) }
        end

        # The log as the test runner printed it, without what `gh` puts before each line.
        def plain(log) = log.lines.map { |line| line.sub(PREFIX, "") }.join

        # Runs `gh` as `CiRuns::FailedJobs` asks: `(argv, chdir:)`, answering `[ok, output]`.
        def run(argv, chdir: nil)
          [true, @gh.call(*argv.drop(1))]
        rescue ConsoleCapture::Failure => e
          [false, e.message.sub(REFUSED, "")]
        end
      end
    end
  end
end
