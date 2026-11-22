# frozen_string_literal: true

require "time"
require_relative "../console_capture"

module Hecks
  module Adapters
    class GithubPullRequests
      # Deletes the origin branches of train pull requests that are settled. A train branch is never
      # reused, so one whose pull requests are all merged, or closed longer than the grace period
      # ago, is deleted; one with an open pull request, a recent closure (a closed pull request may
      # be reopened), a closure from this same sweep, or no pull request at all is kept.
      class TrainBranchPrune
        # Seconds a closed, unmerged pull request keeps its branch before the branch is deleted.
        GRACE = 3600

        # @param rest [#train_refs, #closed_pulls] the REST reader of branches and closed pulls
        # @param github [#call] takes the `gh` arguments and answers stdout; raises on failure
        # @param now [Time] the moment the grace period is measured from
        def initialize(rest, github, now)
          @rest = rest
          @gh = github
          @now = now
        end

        # @param prefix [String] the branch prefix of the train branches considered
        # @param open [Array<Hash>] the open pull requests, each with its `headRefName`
        # @param skip [Array<Integer>] pull request numbers closed in this sweep
        # @return [Array<String>] one line per branch deleted, or kept for a refused delete
        def run(prefix, open, skip)
          held = open.map { |pull| pull["headRefName"] }
          pulls = @rest.closed_pulls(prefix).group_by { |pull| pull["headRefName"] }
          @rest.train_refs(prefix).filter_map do |ref|
            delete(ref, pulls[ref]) if settled?(ref, held, pulls[ref], skip)
          end
        end

        private

        def settled?(ref, held, pulls, skip)
          return false if pulls.nil? || held.include?(ref)

          pulls.all? { |pull| !skip.include?(pull["number"]) && over?(pull) }
        end

        def over?(pull)
          return true if pull["mergedAt"]

          Time.parse(pull["closedAt"].to_s) <= @now - GRACE
        rescue ArgumentError
          false
        end

        def delete(ref, pulls)
          @gh.call("api", "-X", "DELETE", "repos/{owner}/{repo}/git/refs/heads/#{ref}")
          last = pulls.max_by { |pull| pull["number"] }
          "deleted #{ref}: ##{last["number"]} #{last["mergedAt"] ? "merged" : "closed"}"
        rescue ConsoleCapture::Failure => e
          "kept #{ref}: #{e.message}"
        end
      end
    end
  end
end
