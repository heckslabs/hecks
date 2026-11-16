# frozen_string_literal: true

require "json"
require_relative "../console_capture"
require_relative "../git_train/pull_request_boarding"
require_relative "../gh_rest"
require_relative "checks"
require_relative "pull_cache"

module Hecks
  module Adapters
    class CiRuns
      # The train's pull request for a boarded commit, read through `gh api`. A boarding that went
      # to main as a pull request is squash-merged by GitHub into a commit of its own, so CI is
      # judged on that commit, not on the local one. The pull request is found by its branch, which
      # the boarded commit names, or else by the commit: a commit boarded beneath a later one rides
      # the train named for that later commit. The reads are REST, whose budget is apart from
      # GraphQL's, which the pipeline's other readers and the owner's tools share.
      class PullRequest
        # The head branch prefix of a train pull request.
        PREFIX = "train/main-"

        # @param runner [#call] takes `(argv, chdir:)` and answers `[ok, output]`
        # @param checkout [String] the directory `gh` runs in
        # @param landed [String] the boarded commit
        # @param cache [PullCache] what this process has read of the pull request lately
        def initialize(runner, checkout, landed, cache: PullCache.shared)
          @cache = cache
          @runner = runner
          @checkout = checkout
          @landed = landed
          @branch = GitTrain::PullRequestBoarding.branch_for(landed)
        end

        # @return [Hash, nil] `number`, `state` (`OPEN`, `MERGED`, `CLOSED`), `mergeCommit`,
        #   `statusCheckRollup`, `commits`, `createdAt` and `comments`; nil when the boarding has
        #   no pull request
        # @raise [ConsoleCapture::Failure] when `gh` cannot read the branch
        def read
          @cache.read(@branch) do
            rest = GhRest.new(method(:api))
            rest.pull(@branch) || rest.carrying(@landed, PREFIX)
          end
        end

        # @return [Checks, nil] the checks of the open pull request; nil when there is none or it is
        #   merged or closed
        # @raise [ConsoleCapture::Failure] when `gh` cannot read the branch
        def checks
          pull = read
          Checks.new(pull["statusCheckRollup"]) if pull && pull["state"] == "OPEN"
        end

        private

        def api(*arguments)
          ok, output = @runner.call(["gh", *arguments], chdir: @checkout)
          raise ConsoleCapture::Failure, "gh api failed: #{output.to_s.strip}" unless ok

          JSON.parse(output.to_s)
        rescue JSON::ParserError
          raise ConsoleCapture::Failure, "gh api answered no JSON"
        end
      end
    end
  end
end
