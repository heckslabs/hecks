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

      # A commit sha as GitHub accepts it in an API path.
      SHA_PATTERN = /\A[0-9a-fA-F]{7,40}\z/

      # Check runs asked for per page; GitHub's maximum.
      PER_PAGE = 100

      # Asks GitHub by commit sha, matching `Clearance`'s identity, so it works after the
      # branch is gone. `{owner}/{repo}` is a `gh api` template resolved from the git remote.
      #
      # @param commit [Hash, String] a materialized value object (`{value: sha}`) or a bare sha
      # @return [Hash] `{ summary: { value: ... } }` when every check is green
      # @raise [RuntimeError] when the sha is malformed, `gh` is missing or fails, no checks
      #   exist, any are incomplete, or any failed
      def run(commit:, **)
        sha = valid_sha(commit)
        runs = settled_runs(sha)
        failing = runs.reject { |run| PASSING.include?(run["conclusion"]) }
        raise failure_message(failing, runs, sha) unless failing.empty?

        { summary: { value: "#{runs.length} checks, all green (#{sha[0, 7]})" } }
      end

      private

      def valid_sha(commit)
        sha = sha_of(commit)
        raise "not a commit sha: #{sha.inspect}" unless sha.match?(SHA_PATTERN)

        sha
      end

      # The check runs against `sha`, once none is still running.
      def settled_runs(sha)
        runs = check_runs(sha)
        raise "gh reports no checks at all against #{sha}" if runs.empty?

        # Refuse rather than answer on an incomplete run; asking again once it settles is safe.
        incomplete = runs.reject { |run| run["status"] == "completed" }
        raise "checks against #{sha} are still running — asked before they settled" if incomplete.any?

        runs
      end

      def failure_message(failing, runs, sha)
        "#{failing.length} of #{runs.length} checks failed against #{sha[0, 7]}: " \
          "#{failing.map { |run| run["name"] }.join(", ")}"
      end

      # Accepts a materialized value hash with symbol or string keys, or a bare string.
      def sha_of(commit)
        return commit if commit.is_a?(String)

        (commit.key?(:value) ? commit[:value] : commit["value"]).to_s
      end

      # Every page of check runs: a red run past the first page must still be seen.
      def check_runs(sha)
        runs = []
        page = 1
        loop do
          batch = check_run_page(sha, page)["check_runs"] || []
          runs.concat(batch)
          break if batch.length < PER_PAGE

          page += 1
        end
        runs
      end

      def check_run_page(sha, page)
        path = "repos/{owner}/{repo}/commits/#{sha}/check-runs?per_page=#{PER_PAGE}&page=#{page}"
        out, err, status = Open3.capture3("gh", "api", path)
        raise "gh api check-runs failed for #{sha}: #{err.strip.empty? ? out.strip : err.strip}" unless status.success?

        JSON.parse(out)
      rescue Errno::ENOENT
        raise "gh is not installed or not on PATH — cannot read check runs for #{sha}"
      end
    end
  end
end
