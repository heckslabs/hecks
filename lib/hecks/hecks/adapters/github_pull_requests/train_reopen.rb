# frozen_string_literal: true

require "json"
require_relative "../console_capture"
require_relative "../ci_runs/reopen_marker"

module Hecks
  module Adapters
    class GithubPullRequests
      # One close and reopen of a train pull request whose CI never started, which makes GitHub
      # start its CI run again. The marker comments go before and after, so a read between the
      # close and the reopen sees the pull request as reopening, not closed, and a later read
      # reports it reopened once. Auto-merge is turned on again, since closing may clear it.
      class TrainReopen
        # The fields read before the pull request is touched.
        FIELDS = "number,state,statusCheckRollup"

        # @param github [#call] runs `gh` with its arguments and answers its stdout, raising
        #   `ConsoleCapture::Failure` when GitHub refuses
        def initialize(github)
          @gh = github
        end

        # @param number [String] the pull request's number
        # @return [String] the report: the pull request closed and reopened
        # @raise [ConsoleCapture::Failure] when it is not open, has checks, or GitHub refuses
        def run(number)
          check!(JSON.parse(@gh.call("pr", "view", number, "--json", FIELDS)), number)
          @gh.call("pr", "comment", number, "--body", CiRuns::ReopenMarker::REOPENING)
          @gh.call("pr", "close", number)
          @gh.call("pr", "reopen", number)
          @gh.call("pr", "merge", number, "--auto", "--squash")
          @gh.call("pr", "comment", number, "--body", CiRuns::ReopenMarker::REOPENED)
          "closed and reopened PR #{number} to start its CI, and turned auto-merge on again"
        rescue JSON::ParserError
          raise ConsoleCapture::Failure, "gh pr view answered no JSON"
        end

        private

        # The facts the request was made on can be stale by the time it runs: a pull request that
        # closed or got checks since is left alone.
        def check!(pull, number)
          raise ConsoleCapture::Failure, "PR #{number} is #{pull["state"]}: not reopened" unless pull["state"] == "OPEN"

          checks = Array(pull["statusCheckRollup"]).size
          raise ConsoleCapture::Failure, "PR #{number} has #{checks} checks: not reopened" if checks.positive?
        end
      end
    end
  end
end
