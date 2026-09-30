# frozen_string_literal: true

require "open3"
require "json"

module Hecks
  module Adapters
    # The `CI` port adapter: answers `Clearance.CI.Run` from GitHub's check runs for a commit.
    # Raises when no checks exist, any are still running, or any failed.
    class GithubChecks
      # All keywords are unused; the adapter takes no per-boot configuration.
      def initialize(aggregate: nil, settings: {}, root: nil); end

      # Check-run conclusions that count as green; `skipped` covers path-filtered workflows.
      PASSING = %w[success neutral skipped].freeze

      # Asks GitHub by commit sha, matching `Clearance`'s identity, so it works after the
      # branch is gone. `{owner}/{repo}` is a `gh api` template resolved from the git remote.
      #
      # @param commit [Hash, String] a materialized value object (`{value: sha}`) or a bare sha
      # @return [Hash] `{ summary: { value: ... } }` when every check is green
      # @raise [RuntimeError] when no checks exist, any are incomplete, or any failed
      def run(commit:, **)
        sha = sha_of(commit)
        runs = check_runs(sha)

        raise "gh reports no checks at all against #{sha}" if runs.empty?

        # Refuse rather than answer on an incomplete run; asking again once it settles is safe.
        incomplete = runs.reject { |run| run["status"] == "completed" }
        raise "checks against #{sha} are still running — asked before they settled" if incomplete.any?

        failing = runs.reject { |run| PASSING.include?(run["conclusion"]) }
        return { summary: { value: "#{runs.length} checks, all green (#{sha[0, 7]})" } } if failing.empty?

        raise "#{failing.length} of #{runs.length} checks failed against #{sha[0, 7]}: " \
              "#{failing.map { |run| run['name'] }.join(', ')}"
      end

      private

      # Accepts a materialized value hash with symbol or string keys, or a bare string.
      def sha_of(commit)
        return commit if commit.is_a?(String)

        (commit.key?(:value) ? commit[:value] : commit["value"]).to_s
      end

      def check_runs(sha)
        out, err, status = Open3.capture3("gh", "api", "repos/{owner}/{repo}/commits/#{sha}/check-runs")
        raise "gh api check-runs failed for #{sha}: #{err.strip.empty? ? out.strip : err.strip}" unless status.success?

        JSON.parse(out)["check_runs"] || []
      end
    end
  end
end
