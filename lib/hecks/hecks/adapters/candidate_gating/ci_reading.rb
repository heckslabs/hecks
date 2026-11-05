# frozen_string_literal: true

require "json"
require_relative "../console_capture"
require_relative "../candidate_gate"
require_relative "../main_integration/command_runner"

module Hecks
  module Adapters
    class CandidateGating
      # The CI run of one commit on one branch, read through `gh`: none yet, still running,
      # passed, or failed with the jobs that did not succeed.
      class CiReading
        # The workflow whose run is read, as GitHub names it.
        WORKFLOW = "CI"

        # One run as read: its id, its verdict and the failed jobs.
        Run = Struct.new(:id, :verdict, :jobs, keyword_init: true) do
          # @return [String] the run id and verdict, and the failed jobs when red, in words
          def to_s
            tail = verdict == :failed ? "; failed jobs: #{jobs}" : ""
            "#{WORKFLOW} run #{id} #{verdict}#{tail}"
          end
        end

        # @param checkout [String] a directory inside the repository
        # @param runner [#call, nil] takes `(argv, chdir:)` and answers `[ok, output]`; the command
        #   runner when nil. A spec replaces it with a fake GitHub.
        def initialize(checkout, runner: nil)
          @checkout = checkout
          @runner = runner || MainIntegration::CommandRunner.new
        end

        # @param commit [String] the commit whose run is read
        # @param branch [String] the branch the run was on
        # @return [Run, nil] the run, with `verdict:` `:running`, `:passed` or `:failed`; nil
        #   when the branch has no run of the commit
        # @raise [ConsoleCapture::Failure] when `gh` cannot be read
        def run_of(commit, branch: CandidateGate::BRANCH)
          run = gh("run", "list", "--workflow", WORKFLOW, "--branch", branch, "--event", "push", "--commit", commit,
                   "--json", "databaseId,status,conclusion", "--limit", "1").first
          return unless run

          id = run["databaseId"].to_s
          Run.new(id: id, verdict: verdict(run), jobs: run["conclusion"] == "success" ? "" : failed_jobs(id))
        end

        private

        def verdict(run)
          return :running unless run["status"] == "completed"

          run["conclusion"] == "success" ? :passed : :failed
        end

        def failed_jobs(id)
          return "" if id.empty?

          jobs = gh("run", "view", id, "--json", "jobs").fetch("jobs", [])
          names = jobs.reject { |job| Hecks::CheckConclusion.clean?(job["conclusion"]) }.map { |job| job["name"] }
          names.empty? ? "none named" : names.join(", ")
        end

        def gh(*args)
          ok, output = @runner.call(["gh", *args], chdir: @checkout)
          raise ConsoleCapture::Failure, "gh #{args.first(2).join(" ")} failed: #{output.to_s.strip}" unless ok

          JSON.parse(output)
        rescue JSON::ParserError
          raise ConsoleCapture::Failure, "gh #{args.first(2).join(" ")} answered no JSON"
        end
      end
    end
  end
end
