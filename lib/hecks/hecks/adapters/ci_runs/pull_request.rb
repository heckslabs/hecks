# frozen_string_literal: true

require "json"
require_relative "../console_capture"
require_relative "../git_train/pull_request_boarding"
require_relative "checks"

module Hecks
  module Adapters
    class CiRuns
      # The train's pull request for a boarded commit, read through `gh`. A boarding that went to
      # main as a pull request is squash-merged by GitHub into a commit of its own, so CI is
      # judged on that commit, not on the local one. The pull request is found by its branch, which
      # the boarded commit names.
      class PullRequest
        # What `gh` says when the branch has no pull request (a boarding that was a plain push).
        NONE = /no pull requests found/i

        # The fields read from the pull request.
        FIELDS = "number,state,mergeCommit,statusCheckRollup"

        # @param runner [#call] takes `(argv, chdir:)` and answers `[ok, output]`
        # @param checkout [String] the directory `gh` runs in
        # @param landed [String] the boarded commit
        def initialize(runner, checkout, landed)
          @runner = runner
          @checkout = checkout
          @branch = GitTrain::PullRequestBoarding.branch_for(landed)
        end

        # @return [Hash, nil] `number`, `state` (`OPEN`, `MERGED`, `CLOSED`), `mergeCommit` and
        #   `statusCheckRollup`; nil when the boarding has no pull request
        # @raise [ConsoleCapture::Failure] when `gh` cannot read the branch for another reason
        def read
          ok, output = @runner.call(["gh", "pr", "view", @branch, "--json", FIELDS], chdir: @checkout)
          return JSON.parse(output.to_s) if ok
          return nil if output.to_s.match?(NONE)

          raise ConsoleCapture::Failure, "gh pr view failed: #{output.to_s.strip}"
        rescue JSON::ParserError
          raise ConsoleCapture::Failure, "gh pr view answered no JSON"
        end

        # @return [Checks, nil] the checks of the open pull request; nil when there is none or it is
        #   merged or closed
        # @raise [ConsoleCapture::Failure] when `gh` cannot read the branch
        def checks
          pull = read
          Checks.new(pull["statusCheckRollup"]) if pull && pull["state"] == "OPEN"
        end
      end
    end
  end
end
