# frozen_string_literal: true

require "json"
require_relative "../console_capture"
require_relative "../main_integration/failure_log"

module Hecks
  module Adapters
    class CiRuns
      # The facts of a red train pull request, read through `gh`: the CI run and the attempt that
      # failed, the failed jobs, the spec files the failed log names (or the failed steps when it
      # names none) with its first failure lines, and the commits the pull request carries. It decides
      # nothing; the TrainPr policies decide whether to rerun.
      class TrainPrFailure
        # The spec files an rspec failure summary names: `rspec ./spec/x_spec.rb:12 # description`.
        SPEC_LINE = %r{rspec (?:\./)?(\S+?_spec\.rb)}

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
          id = run["databaseId"].to_s
          log = failed_log(id)
          specs = log.scan(SPEC_LINE).flatten.uniq
          base(pull, run, specs).merge(report: report(pull, id, specs, log))
        end

        private

        def base(pull, run, specs)
          number = pull["number"].to_s
          attempt = run["attempt"].to_i
          { pr: number, ci_run: run["databaseId"].to_s, attempt: attempt, specs: specs.join(","),
            failure_key: "#{@landed[0, 12]}-#{run["databaseId"]}-#{attempt}", work_key: "red-train-#{number}",
            title: "Red train PR #{number}: #{specs.first || "CI failed"}" }
        end

        def report(pull, id, specs, log)
          what = specs.empty? ? "failed steps: #{steps(id)}" : "specs: #{specs.join(", ")}"
          "PR #{pull["number"]} (#{@landed[0, 10]}) CI run #{id} failed; #{what}; commits: #{commits(pull)}\n" \
            "#{first_lines(log)}\n#{INSTRUCTION}"
        end

        def first_lines(log)
          kept = log.lines.first(LINES)
          kept.join.strip
        end

        def commits(pull) = Array(pull["commits"]).map { |c| "#{c["oid"].to_s[0, 10]} #{c["messageHeadline"]}" }.join("; ")

        def latest_run
          gh("run", "list", "--workflow", CiRuns::WORKFLOW, "--branch", @branch, "--limit", "1",
             "--json", "databaseId,attempt").first or raise ConsoleCapture::Failure, "no CI run for #{@branch}"
        end

        def steps(id)
          jobs = gh("run", "view", id, "--json", "jobs").fetch("jobs", [])
          failed = jobs.reject { |job| Hecks::CheckConclusion.clean?(job["conclusion"]) }
          failed.flat_map { |job| failed_steps(job) }.join(", ")
        end

        def failed_steps(job)
          bad = Array(job["steps"]).reject { |step| Hecks::CheckConclusion.clean?(step["conclusion"]) }
          bad.map { |step| "#{job["name"]}/#{step["name"]}" }.then { |names| names.empty? ? [job["name"]] : names }
        end

        def failed_log(id)
          ok, output = @runner.call(["gh", "run", "view", id, "--log-failed"], chdir: @checkout)
          ok ? output.to_s : ""
        end

        def gh(*args)
          ok, output = @runner.call(["gh", *args], chdir: @checkout)
          raise ConsoleCapture::Failure, "gh #{args.first(2).join(" ")} failed: #{output.to_s.strip}" unless ok

          JSON.parse(output)
        end
      end
    end
  end
end
