# frozen_string_literal: true

require "json"
require "time"
require_relative "cache"
require_relative "pipeline_github/settled_counts"
require_relative "pipeline_github/runs"
require_relative "pipeline_github/train_runs"
require_relative "pipeline_github/pull_checks"
require_relative "../../cache_dir"

module Hecks
  module Adapters
    # The `GitHub` port's adapter: answers `CiRuns` and `SlowestJobs` with CI as GitHub reports it,
    # read through `gh run list` and `gh run view`. It only reads, and keeps every read for a few
    # seconds.
    class PipelineGitHub
      include PipelineBoard::PipelineRuns
      include PipelineBoard::TrainRuns

      WORKFLOW = "ci.yml"
      BRANCH = "main"

      # A release tag that names a version, such as `v7.0.0`.
      VERSION_TAG = /\Av\d/

      # @param aggregate [Object, nil] unused
      # @param settings [Hash] `gh:` stands in for the program (a callable taking the arguments and
      #   answering parsed JSON), `ttl:` for how long a read is kept
      # @param root [String, nil] the checkout `gh` runs in
      def initialize(aggregate: nil, settings: {}, root: nil)
        @gh = settings[:gh] || ->(*args) { PipelineBoard::Probe.json("gh", *args, chdir: root) }
        @cache = PipelineBoard::Cache.new(ttl: settings.fetch(:ttl, 20))
        @settled = PipelineBoard::SettledCounts.new(settled_path(settings))
      end

      # @param limit [Hash, Integer, nil] how many runs (20 when none is named)
      # @return [Hash{Symbol => String}] `text:` the runs, oldest first, as JSON
      # @raise [PipelineBoard::Unavailable] when `gh` cannot answer
      def ci_runs(limit: nil)
        { text: JSON.generate(rows(count(limit, 20))) }
      end

      # @param limit [Hash, Integer, nil] how many jobs (8 when none is named)
      # @return [Hash{Symbol => String}] `text:` the last completed run's slowest jobs as JSON
      # @raise [PipelineBoard::Unavailable] when `gh` cannot answer
      def slowest_jobs(limit: nil)
        { text: JSON.generate(slowest(count(limit, 8))) }
      end

      # @param limit [Hash, Integer, nil] how many runs (20 when none is named)
      # @return [Hash{Symbol => String}] `text:` the first-attempt CI runs of train pull requests,
      #   oldest first, as JSON; reruns are left out
      # @raise [PipelineBoard::Unavailable] when `gh` cannot answer
      def train_ci_runs(limit: nil)
        { text: JSON.generate(train_rows(count(limit, 20))) }
      end

      # @param limit [Hash, Integer, nil] how many jobs (8 when none is named)
      # @return [Hash{Symbol => String}] `text:` the slowest jobs of the latest completed train run
      # @raise [PipelineBoard::Unavailable] when `gh` cannot answer
      def train_slowest_jobs(limit: nil)
        { text: JSON.generate(train_slowest(count(limit, 8))) }
      end

      # @return [String] the repository's web address, the base of its commit links
      # @raise [PipelineBoard::Unavailable] when `gh` cannot answer
      def repo_url = read("repo", "view", "--json", "url")["url"].to_s

      # @return [Hash, nil] the newest `v` release: `tag`, `published` and `published_at`
      # @raise [PipelineBoard::Unavailable] when `gh` cannot answer
      def latest_release
        listed = read("release", "list", "--limit", "20", "--json", "tagName,isDraft,isPrerelease,publishedAt")
        found = listed.find { |release| release["tagName"].to_s.match?(VERSION_TAG) }
        raise PipelineBoard::Unavailable, "no v release found" unless found

        { tag: found["tagName"], published: !found["isDraft"], published_at: found["publishedAt"] }
      end

      # @return [Array<Hash>] the open pull requests on `train/` branches with their checks counted:
      #   `number`, `branch`, `passed`, `failed`, `pending` and `total`
      # @raise [PipelineBoard::Unavailable] when `gh` cannot answer
      def train_prs = PipelineBoard::PullChecks.train(open_list)

      # @return [Hash] the open pull requests: `count`, the `oldest` creation time (nil when none),
      #   the newest `train` pull request's number (nil when none) and `capped`, true when the
      #   list may hold more than the `gh` limit shows
      # @raise [PipelineBoard::Unavailable] when `gh` cannot answer
      def open_prs = PipelineBoard::PullChecks.open(open_list)

      # @return [Hash, nil] the newest CI run on main, as {#ci_runs} rows are
      # @raise [PipelineBoard::Unavailable] when `gh` cannot answer
      def latest_run = rows(1).last

      private

      # The file the settled counts live in: `settled_path:` when named, else under the cache
      # directory for the real `gh`; a stubbed `gh` keeps them in memory only.
      def settled_path(settings)
        return settings[:settled_path] if settings.key?(:settled_path)

        File.join(Hecks::CacheDir.path("pipeline_board"), "settled_runs.json") unless settings[:gh]
      end

      def count(value, default)
        number = value.is_a?(Hash) ? value[:value] : value
        number.to_i.positive? ? number.to_i : default
      end

      # The one `gh pr list` both readings share, so the board asks GitHub once for it.
      def open_list
        limit = PipelineBoard::PullChecks::LIMIT.to_s
        read("pr", "list", "--state", "open", "--limit", limit, "--json", PipelineBoard::PullChecks::FIELDS)
      end

      def read(*args) = @cache.fetch(args) { @gh.call(*args) }
    end
  end
end
