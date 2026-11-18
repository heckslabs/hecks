# frozen_string_literal: true

require_relative "../console_capture"

module Hecks
  module Adapters
    class GithubBranchCi
      # Waits for the CI workflow's pull-request run of one commit to end, reading it at a fixed
      # pace for at most the minutes it is given.
      class RunWait
        # The workflow whose run is read, as GitHub names it.
        WORKFLOW = "CI"

        # Seconds between two reads of the run.
        EVERY = 20

        # @param github [GhCall] the calls to GitHub
        # @param pause [#call, nil] takes seconds; `Kernel.sleep` when nil
        # @param minutes [Numeric] the longest wait
        def initialize(github, pause:, minutes:)
          @github = github
          @pause = pause || ->(seconds) { sleep(seconds) }
          @reads = (minutes * 60 / EVERY).ceil + 1
        end

        # @param sha [String] the pushed head
        # @return [Hash] the ended run, as GitHub's REST answers it
        # @raise [ConsoleCapture::Failure] naming the run's state when the wait runs out
        def completed(sha)
          @reads.times do |read|
            run = latest(sha)
            return run if run && run["status"] == "completed"

            @pause.call(EVERY) unless read == @reads - 1
          end
          raise ConsoleCapture::Failure, unfinished(sha)
        end

        private

        def latest(sha)
          runs = @github.api("actions/runs?head_sha=#{sha}&event=pull_request&per_page=100").fetch("workflow_runs", [])
          runs.select { |run| run["name"] == WORKFLOW }.max_by { |run| run["id"].to_i }
        end

        def unfinished(sha)
          run = latest(sha)
          state = run ? "run #{run["id"]} is #{run["status"]}" : "no #{WORKFLOW} run has started"
          "CI at #{sha[0, 10]}: #{state} after the wait; ask again with EarlyCi.retry! at the same sha"
        end
      end
    end
  end
end
