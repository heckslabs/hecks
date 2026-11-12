# frozen_string_literal: true

require "json"
require_relative "../console_capture"
require_relative "../main_integration/failure_log"
require_relative "failed_jobs"

module Hecks
  module Adapters
    class CiRuns
      # The facts of a red train pull request, read through `gh`: the CI run and the attempt that
      # failed, each failed job read on its own, the spec files the jobs that reached the specs
      # name (or the failed steps of the others) with their first failure lines, and the commits
      # the pull request carries. A pull request is a `spec` failure when any one job reached the
      # specs, the one roll-up the single `cause` of a `TrainPr` needs; a setup failure in another
      # job never hides it. The TrainPr policies decide whether to rerun.
      class TrainPrFailure
        # What a failure before the specs ran is told: nothing in the code is wrong.
        SETUP_NOTE = "A step before the specs ran failed; no example failed, so there is no code to fix."

        # How many of the failed log's lines the report keeps.
        LINES = 12

        # What the Work item is told to do.
        INSTRUCTION = "Fix on local main, land it, do not push."

        # @param runner [#call] takes `(argv, chdir:)` and answers `[ok, output]`
        # @param checkout [String] the directory `gh` runs in
        # @param branch [String] the pull request's branch
        # @param landed [String] the boarded commit
        def initialize(runner, checkout, branch, landed)
          @runner = runner
          @checkout = checkout
          @branch = branch
          @landed = landed
        end

        # @param pull [Hash] the pull request as `PullRequest#read` answers it
        # @return [Hash{Symbol => Object}] the answer fields: `outcome`, `report` and the facts
        def facts(pull)
          run = latest_run
          @jobs = jobs_of(run["databaseId"].to_s)
          @spec_jobs = @jobs.select(&:spec?)
          cause = @spec_jobs.empty? ? "setup" : "spec"
          specs = @spec_jobs.flat_map(&:specs).uniq
          base(pull, run, specs, cause).merge(step: steps, report: report(pull, run, specs, cause))
        end

        private

        # The failed jobs, or the whole failed log as one job when `gh` names none or cannot list
        # them. A log that cannot be read either leaves the failure unclassified: it is refused.
        def jobs_of(id)
          jobs = listed_jobs(id)
          return jobs unless jobs.empty?

          ok, output = @runner.call(["gh", "run", "view", id, "--log-failed"], chdir: @checkout)
          raise ConsoleCapture::Failure, "gh run view failed: #{output.to_s.strip}" unless ok

          [FailedJobs::Job.new(nil, "CI", ["CI"], output.to_s)]
        end

        def listed_jobs(id)
          FailedJobs.new(@runner, @checkout).read(id)
        rescue ConsoleCapture::Failure
          []
        end

        def steps = @jobs.flat_map(&:steps).join(", ")

        def base(pull, run, specs, cause)
          number = pull["number"].to_s
          attempt = run["attempt"].to_i
          { pr: number, ci_run: run["databaseId"].to_s, attempt: attempt, specs: specs.join(","), cause: cause,
            failure_key: "#{@landed[0, 12]}-#{run["databaseId"]}-#{attempt}", work_key: "red-train-#{number}",
            title: "Red train PR #{number}: #{specs.first || "CI failed"}" }
        end

        def report(pull, run, specs, cause)
          what = specs.empty? ? "failed steps: #{steps}" : "specs: #{specs.join(", ")}"
          "PR #{pull["number"]} (#{@landed[0, 10]}) CI run #{run["databaseId"]} failed; #{what}; " \
            "commits: #{commits(pull)}\n#{first_lines(cause)}\n#{cause == "spec" ? INSTRUCTION : SETUP_NOTE}"
        end

        # The first lines of the failed log of the jobs that explain the failure.
        def first_lines(cause)
          lines = explaining_log(cause).lines
          lines.first(LINES).join.strip
        end

        def explaining_log(cause) = (cause == "spec" ? @spec_jobs : @jobs).map(&:log).join("\n")

        def commits(pull) = Array(pull["commits"]).map { |c| "#{c["oid"].to_s[0, 10]} #{c["messageHeadline"]}" }.join("; ")

        def latest_run
          ok, output = @runner.call(["gh", "run", "list", "--workflow", CiRuns::WORKFLOW, "--branch", @branch, "--limit", "1",
                                     "--json", "databaseId,attempt"], chdir: @checkout)
          raise ConsoleCapture::Failure, "gh run list failed: #{output.to_s.strip}" unless ok

          JSON.parse(output).first or raise ConsoleCapture::Failure, "no CI run for #{@branch}"
        end
      end
    end
  end
end
