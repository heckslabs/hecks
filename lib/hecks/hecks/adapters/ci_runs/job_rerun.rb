# frozen_string_literal: true

require_relative "../console_capture"
require_relative "rerun_report"

module Hecks
  module Adapters
    class CiRuns
      # A rerun of one failed job of a CI run, by itself, over GitHub's REST endpoint
      # (`POST actions/jobs/{id}/rerun`), whose budget is apart from GraphQL's.
      class JobRerun
        # A job GitHub can rerun is named by its numeric id.
        JOB_ID = /\A\d+\z/

        # @param runner [#call] takes `(argv, chdir:)` and answers `[ok, output]`
        # @param checkout [String] the directory `gh` runs in
        def initialize(runner, checkout)
          @runner = runner
          @checkout = checkout
        end

        # @param held [Hash{Symbol => Object}] `job`, and `ci_run`, `pr` and `examples` for its
        #   report
        # @return [String] the report of the rerun
        # @raise [ConsoleCapture::Failure] when no job is named or GitHub refuses the rerun
        def run(held)
          job = held[:job].to_s
          raise ConsoleCapture::Failure, "no failed job named to rerun (#{job.inspect})" unless job.match?(JOB_ID)

          argv = ["gh", "api", "-X", "POST", "repos/{owner}/{repo}/actions/jobs/#{job}/rerun"]
          ok, output = @runner.call(argv, chdir: @checkout)
          raise ConsoleCapture::Failure, "gh api job rerun failed: #{output.to_s.strip}" unless ok

          RerunReport.job(job, held)
        end
      end
    end
  end
end
