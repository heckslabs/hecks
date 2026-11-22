# frozen_string_literal: true

module Hecks
  module Adapters
    class GithubPullRequests
      # One turning on of auto-merge for a train pull request the merge queue dropped, which
      # enqueues it again.
      class TrainArm
        # @param github [#call] runs `gh` with its arguments and answers its stdout, raising
        #   `ConsoleCapture::Failure` when GitHub refuses
        def initialize(github)
          @gh = github
        end

        # @param number [String] the pull request's number
        # @return [String] the report: auto-merge turned on
        # @raise [ConsoleCapture::Failure] when GitHub refuses
        def run(number)
          @gh.call("pr", "merge", number, "--auto", "--merge")
          "turned auto-merge on again for PR #{number}: GitHub enqueues it"
        end
      end
    end
  end
end
