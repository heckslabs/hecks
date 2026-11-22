# frozen_string_literal: true

require_relative "gh_rest/rollup"

module Hecks
  module Adapters
    # Reads pull requests, releases and the repository through GitHub's REST endpoints, whose hourly
    # budget is apart from GraphQL's, and answers them in the shapes `gh pr view --json` and
    # `gh pr list --json` gave, so the readers of a pull request stay as they were. It is a
    # library behind two adapters: the `CiRuns` adapter (the beat's read of a train pull request)
    # and `PipelineGitHub`, the `GitHub` port's adapter (the board's reads), each handing it the
    # one call it can make.
    #
    # Every list is read whole (`--paginate --slurp`, 100 to a page), so a pull request with more
    # checks than one page holds is counted in full.
    class GhRest
      PAGE = 100

      # The first line of a commit message, its headline.
      FIRST_LINE = /\A[^\n]*/

      # @param reader [#call] takes `gh`'s arguments and answers its parsed JSON
      def initialize(reader)
        @gh = reader
        @rollup = Rollup.new(method(:listed))
      end

      # @param branch [String] a pull request's head branch
      # @return [Hash, nil] `number`, `url`, `state` (`OPEN`, `CLOSED`, `MERGED`), `mergeCommit`,
      #   `createdAt`, `commits`, `comments` and `statusCheckRollup`; nil when the branch has none
      def pull(branch)
        found = listed("repos/{owner}/{repo}/pulls?state=all&head={owner}:#{branch}&per_page=#{PAGE}").first
        found && shaped(found).merge(detail(found))
      end

      # The pull request under `prefix` whose commits hold `sha`, found by the commit, not by its
      # branch: a commit rides a train named for a later commit when it was boarded beneath it.
      # An open one comes first, then the newest merged one; one closed unmerged never counts.
      #
      # @param sha [String] the full commit
      # @param prefix [String] the head branch prefix of the pull requests that count
      # @return [Hash, nil] the pull request in the shape `pull` answers; nil when none holds it
      def carrying(sha, prefix)
        found, row = holding(sha, prefix).max_by { |_, held| [held["state"] == "OPEN" ? 1 : 0, held["number"].to_i] }
        found && row.merge(detail(found))
      end

      # @param limit [Integer] how many open pull requests
      # @param prefix [String] the branch prefix of the pull requests whose checks are read too
      # @return [Array<Hash>] `number`, `headRefName`, `headRefOid`, `createdAt` and, for a branch
      #   under `prefix`, its `statusCheckRollup`; one list call, and two more for each such
      #   branch
      def open_pulls(limit, prefix)
        @gh.call("api", "repos/{owner}/{repo}/pulls?state=open&per_page=#{limit}").map do |pull|
          row = shaped(pull)
          row = row.merge("statusCheckRollup" => rollup(pull)) if row["headRefName"].to_s.start_with?(prefix)
          row.slice("number", "headRefName", "headRefOid", "createdAt", "statusCheckRollup")
        end
      end

      # @return [String] the repository's web address
      def repo_url = @gh.call("api", "repos/{owner}/{repo}")["html_url"].to_s

      # @param limit [Integer] how many releases
      # @return [Array<Hash>] the newest releases: `tagName`, `isDraft`, `isPrerelease` and
      #   `publishedAt`
      def releases(limit)
        @gh.call("api", "repos/{owner}/{repo}/releases?per_page=#{limit}").map do |release|
          { "tagName" => release["tag_name"], "isDraft" => release["draft"],
            "isPrerelease" => release["prerelease"], "publishedAt" => release["published_at"] }
        end
      end

      private

      # Every item of a paginated list, across its pages.
      def listed(path, key = nil)
        pages = @gh.call("api", "--paginate", "--slurp", path)
        Array(pages).flat_map { |page| key ? page.fetch(key) : page }
      end

      # Each pull request under `prefix`, open or merged, whose commits hold `sha`, with its shape.
      def holding(sha, prefix)
        rows = listed("repos/{owner}/{repo}/commits/#{sha}/pulls?per_page=#{PAGE}").map { |pull| [pull, shaped(pull)] }
        rows.select { |_, row| row["headRefName"].to_s.start_with?(prefix) && row["state"] != "CLOSED" }
      end

      def shaped(pull)
        merged = !pull["merged_at"].nil?
        { "number" => pull["number"], "url" => pull["html_url"], "headRefName" => pull.dig("head", "ref"),
          "headRefOid" => pull.dig("head", "sha"), "createdAt" => pull["created_at"],
          "state" => merged ? "MERGED" : pull["state"].to_s.upcase,
          "mergeCommit" => (merged ? { "oid" => pull["merge_commit_sha"] } : nil) }
      end

      def detail(pull)
        number = pull["number"]
        { "commits" => commits(number), "comments" => comments(number), "statusCheckRollup" => rollup(pull) }
      end

      def commits(number)
        listed("repos/{owner}/{repo}/pulls/#{number}/commits?per_page=#{PAGE}").map do |commit|
          { "oid" => commit["sha"], "messageHeadline" => headline(commit) }
        end
      end

      def headline(commit) = commit.dig("commit", "message").to_s[FIRST_LINE].to_s.strip

      def comments(number)
        listed("repos/{owner}/{repo}/issues/#{number}/comments?per_page=#{PAGE}").map { |comment| { "body" => comment["body"] } }
      end

      def rollup(pull) = @rollup.of(pull.dig("head", "sha"))
    end
  end
end
