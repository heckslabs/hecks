# frozen_string_literal: true

module Hecks
  module Adapters
    class GithubPullRequests
      # One enqueue again of a train pull request the merge queue dropped: auto-merge is turned on,
      # which enqueues it. A pull request that is already mergeable cannot be armed, since GitHub
      # refuses auto-merge on a clean one; it is merged at once instead (a fallback of this adapter,
      # so the report of an enqueue may name a merge). The merge never passes `--admin`, so branch
      # protection still holds, and a refusal of it raises like any other.
      class TrainArm
        # The words of GitHub's refusal to arm auto-merge on a pull request that is already clean.
        CLEAN_REFUSAL = "clean status"

        # @param github [#call] runs `gh` with its arguments and answers its stdout, raising
        #   `ConsoleCapture::Failure` when GitHub refuses
        def initialize(github)
          @gh = github
        end

        # @param number [String] the pull request's number
        # @return [String] the report: auto-merge turned on, or the pull request merged at once
        # @raise [ConsoleCapture::Failure] when GitHub refuses
        def run(number)
          @gh.call("pr", "merge", number, "--auto", "--merge")
          "turned auto-merge on again for PR #{number}: GitHub enqueues it"
        rescue ConsoleCapture::Failure => e
          raise unless e.message.include?(CLEAN_REFUSAL)

          @gh.call("pr", "merge", number, "--merge")
          "merged PR #{number} at once: auto-merge was refused as it is already mergeable"
        end
      end
    end
  end
end
