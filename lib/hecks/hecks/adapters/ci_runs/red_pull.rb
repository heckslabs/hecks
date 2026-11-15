# frozen_string_literal: true

require_relative "../git_train/pull_request_boarding"
require_relative "settled_facts"
require_relative "train_pr_failure"
require_relative "replaced_runs"

module Hecks
  module Adapters
    class CiRuns
      # What a beat reads of a train pull request's CI runs, kept while the pull request's checks
      # stand as they are: the runs of its tip (which of them a newer run replaced) and, for a red
      # one, the facts of its failure. A settled pull request is read once, not on every beat.
      class RedPull
        # @param runner [#call] takes `(argv, chdir:)` and answers `[ok, output]`
        # @param checkout [String] the directory `gh` runs in
        # @param landed [String] the boarded commit
        def initialize(runner, checkout, landed)
          @runner = runner
          @checkout = checkout
          @landed = landed
        end

        # @param pull [Hash] the pull request as `PullRequest#read` answers it
        # @return [ReplacedRuns] its runs, listed once while its checks stand as they are
        def replaced(pull)
          memo = SettledFacts.new(pull, @landed, label: "runs", symbolize: false)
          ReplacedRuns.new(@runner, @checkout, pull.dig("commits", -1, "oid"), memo: memo)
        end

        # @param pull [Hash] the red pull request
        # @return [Hash{Symbol => Object}] the facts of its failure, with its `report`
        # @raise [ConsoleCapture::Failure] when the failed jobs cannot be read
        def facts(pull)
          branch = GitTrain::PullRequestBoarding.branch_for(@landed)
          SettledFacts.new(pull, @landed).fetch { TrainPrFailure.new(@runner, @checkout, branch, @landed).facts(pull) }.dup
        end

        # A red pull request whose failure `gh` cannot be read for (a 5xx, a missing run, no
        # `gh`) is still watched, so the next observation reads it again and records it once it can.
        #
        # @return [String] the report of the observation that could not read it
        def unreadable(pull, error)
          "#{@landed[0, 10]}: PR #{pull["number"]} CI failed; failed jobs unreadable (#{error.message}); " \
            "retrying next observation"
        end
      end
    end
  end
end
