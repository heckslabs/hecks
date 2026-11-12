# frozen_string_literal: true

require "json"
require_relative "../console_capture"
require_relative "../ci_runs/checks"

module Hecks
  module Adapters
    class GithubPullRequests
      # Closes the open train pull requests that do not need to be open: one whose tip
      # origin/main already holds, and one with failed checks whose tip a newer open train pull
      # request carries, or that local main has moved past. Each is closed with a comment naming why. It reads facts (ancestry and
      # check results) and closes; a closed pull request is not listed again, so a second sweep
      # closes nothing twice.
      class TrainSweep
        # The branch prefix of a train pull request.
        PREFIX = "train/main-"

        # The fields read of each open pull request.
        FIELDS = "number,headRefName,headRefOid,createdAt,statusCheckRollup"

        # @param github [#call] takes the `gh` arguments and answers their stdout; raises on failure
        # @param git [#call] takes the `git` arguments and answers `[ok, output]`
        def initialize(github, git)
          @gh = github
          @git = git
        end

        # @return [Array<String>] one line per pull request closed, empty when none was
        def run
          @git.call(["fetch", "--quiet", "origin"])
          open = pulls
          open.filter_map { |pull| close_if_moot(pull, open) }
        end

        private

        def pulls
          all = JSON.parse(@gh.call("pr", "list", "--state", "open", "--json", FIELDS, "--limit", "100"))
          all.select { |pull| pull["headRefName"].to_s.start_with?(PREFIX) }.sort_by { |pull| pull["createdAt"].to_s }
        end

        def close_if_moot(pull, open)
          why = landed_on_main(pull) || superseded_by(pull, open) || passed_by_main(pull)
          return unless why

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
