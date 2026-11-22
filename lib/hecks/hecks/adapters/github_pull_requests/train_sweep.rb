# frozen_string_literal: true

require "json"
require_relative "../console_capture"
require_relative "../ci_runs/checks"
require_relative "../gh_rest"
require_relative "train_branch_prune"

module Hecks
  module Adapters
    class GithubPullRequests
      # Closes the open train pull requests that do not need to be open: one whose tip
      # origin/main already holds, and one with failed checks whose tip a newer open train pull
      # request carries, or that local main has moved past. Each is closed with a comment naming
      # why. It then deletes the origin train branches whose pull requests are settled (see
      # `TrainBranchPrune`). It reads facts (ancestry, check results, pull request states) and acts;
      # a closed pull request and a deleted branch are not listed again, so a second sweep repeats nothing.
      class TrainSweep
        # The branch prefix of a train pull request.
        PREFIX = "train/main-"

        # @param github [#call] takes the `gh` arguments and answers their stdout; raises on failure
        # @param git [#call] takes the `git` arguments and answers `[ok, output]`
        # @param now [Time] the moment a closed pull request's grace period is measured from
        def initialize(github, git, now: Time.now)
          @gh = github
          @git = git
          @now = now
          @closed = []
          @rest = GhRest.new(method(:read_json))
        end

        # @return [Array<String>] one line per pull request closed and per branch deleted or kept,
        #   empty when there is none
        def run
          @git.call(["fetch", "--quiet", "origin"])
          open = pulls
          lines = open.filter_map { |pull| close_if_moot(pull, open) }
          lines + TrainBranchPrune.new(@rest, @gh, @now).run(PREFIX, open, @closed)
        end

        private

        def pulls
          all = @rest.open_pulls(100, PREFIX)
          all.select { |pull| pull["headRefName"].to_s.start_with?(PREFIX) }.sort_by { |pull| pull["createdAt"].to_s }
        end

        # A REST read of the repository, whose budget is apart from GraphQL's.
        def read_json(*) = JSON.parse(@gh.call(*))

        def close_if_moot(pull, open)
          why = landed_on_main(pull) || superseded_by(pull, open) || passed_by_main(pull)
          return unless why

          @closed << pull["number"]
          @gh.call("pr", "close", pull["number"].to_s, "--comment", why)
          "closed ##{pull["number"]}: #{why}"
        end

        def landed_on_main(pull)
          "its tip #{pull["headRefOid"][0, 10]} is on main already" if ancestor?(pull["headRefOid"], "origin/main")
        end

        def superseded_by(pull, open)
          return unless CiRuns::Checks.new(pull["statusCheckRollup"]).failed_and_complete?

          newer = open.find { |other| other["number"] != pull["number"] && newer?(other, pull) }
          "superseded by ##{newer["number"]}, which carries its tip #{pull["headRefOid"][0, 10]}" if newer
        end

        # A red pull request whose tip local main has passed: the commits after it are the fix, and
        # the order rule keeps their tip from boarding while this pull request stands.
        def passed_by_main(pull)
          return unless CiRuns::Checks.new(pull["statusCheckRollup"]).failed_and_complete?
          return unless ancestor?(pull["headRefOid"], "main") && !ancestor?("main", pull["headRefOid"])

          "local main carries its tip #{pull["headRefOid"][0, 10]} and newer commits"
        end

        def newer?(other, pull)
          other["createdAt"].to_s > pull["createdAt"].to_s && ancestor?(pull["headRefOid"], other["headRefOid"])
        end

        def ancestor?(commit, tip) = @git.call(["merge-base", "--is-ancestor", commit.to_s, tip.to_s]).first
      end
    end
  end
end
