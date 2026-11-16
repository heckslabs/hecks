# frozen_string_literal: true

require "json"
require "time"
require_relative "cache"
require_relative "pipeline_github/settled_counts"
require_relative "pipeline_github/runs"
require_relative "pipeline_github/train_runs"
require_relative "pipeline_github/train_flakes"
require_relative "pipeline_github/ci_records"
require_relative "pipeline_github/pull_checks"
require_relative "pipeline_github/budget"
require_relative "../../hecks/adapters/gh_rest"
require_relative "../../cache_dir"

module Hecks
  module Adapters
    # The `GitHub` port's adapter: answers `CiRuns` and `SlowestJobs` with CI as GitHub reports it,
    # read through `gh run list` and `gh run view`. It only reads, and keeps every read for a few
    # seconds.
    class PipelineGitHub
      include PipelineBoard::PipelineRuns
      include PipelineBoard::TrainRuns
      include PipelineBoard::TrainFlakes
      include PipelineBoard::CiRecords

      WORKFLOW = "ci.yml"
      BRANCH = "main"

      # A release tag that names a version, such as `v7.0.0`.
      VERSION_TAG = /\Av\d/

      # @param aggregate [Object, nil] unused
      # @param settings [Hash] `gh:` stands in for the program (a callable taking the arguments and
      #   answering parsed JSON), `ttl:` for how long a read is kept (the `github_keep_seconds`
      #   setting when none is given)
      # @param root [String, nil] the checkout `gh` runs in
      def initialize(aggregate: nil, settings: {}, root: nil)
        @gh = settings[:gh] || ->(*args) { PipelineBoard::Probe.json("gh", *args, chdir: root) }
        @text = settings[:gh_text] || ->(*args) { PipelineBoard::Probe.run("gh", *args, chdir: root) }
        @cache = PipelineBoard::Cache.kept(settings, "github_keep_seconds")
        @attempts = PipelineBoard::FlakeMemo.new
        @backoff = PipelineBoard::LogBackoff.for(settings)
        @settled = PipelineBoard::SettledCounts.new(settled_path(settings))
        @seats = settings[:seats]
        guard_reads(settings[:pause_percent])
      end

      # @param limit [Hash, Integer, nil] how many runs (20 when none is named)
      # @return [Hash{Symbol => String}] `text:` the runs, oldest first, as JSON
      # @raise [PipelineBoard::Unavailable] when `gh` cannot answer
      def ci_runs(limit: nil)
        { text: JSON.generate(recorded_runs("main", count(limit, 20)) || rows(count(limit, 20))) }
      end

      # @param limit [Hash, Integer, nil] how many jobs (8 when none is named)
      # @return [Hash{Symbol => String}] `text:` the last completed run's slowest jobs as JSON
      # @raise [PipelineBoard::Unavailable] when `gh` cannot answer
      def slowest_jobs(limit: nil)
        { text: JSON.generate(recorded_slowest("main", count(limit, 8)) || slowest(count(limit, 8))) }
      end

      # @param limit [Hash, Integer, nil] how many runs (20 when none is named)
      # @return [Hash{Symbol => String}] `text:` the first-attempt CI runs of train pull requests,
      #   oldest first, as JSON; reruns are left out
      # @raise [PipelineBoard::Unavailable] when `gh` cannot answer
      def train_ci_runs(limit: nil)
        { text: JSON.generate(recorded_runs("train", count(limit, 20)) || train_rows(count(limit, 20))) }
      end

      # @param limit [Hash, Integer, nil] how many jobs (8 when none is named)
      # @return [Hash{Symbol => String}] `text:` the slowest jobs of the latest completed train run
      # @raise [PipelineBoard::Unavailable] when `gh` cannot answer
      def train_slowest_jobs(limit: nil)
        { text: JSON.generate(recorded_slowest("train", count(limit, 8)) || train_slowest(count(limit, 8))) }
      end

      # @param limit [Hash, Integer, nil] how many flakes (5 when none is named)
      # @return [Hash{Symbol => String}] `text:` the items that failed on an earlier attempt of a
      #   train run a later attempt passed, most often first, as JSON with the days it reaches back
      # @raise [PipelineBoard::Unavailable] when `gh` cannot list the runs
      def train_flakes(limit: nil)
        { text: JSON.generate(flake_document(count(limit, 5))) }
      end

      # @return [String] the repository's web address, the base of its commit links
      # @raise [PipelineBoard::Unavailable] when `gh` cannot answer
      def repo_url = @rest.repo_url

      # @return [Hash, nil] the newest `v` release: `tag`, `published` and `published_at`
      # @raise [PipelineBoard::Unavailable] when `gh` cannot answer
      def latest_release
        listed = @rest.releases(20)
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

      # The one list of open pull requests both readings share, so the board asks GitHub once for
      # it: REST, with the checks of the train pull requests only.
      def open_list = @rest.open_pulls(PipelineBoard::PullChecks::LIMIT, PipelineBoard::PullChecks::BRANCH_PREFIX)

      # The budget, measured from `gh api rate_limit` and kept like any other read, and the REST
      # reader whose every call goes through {#read}.
      def guard_reads(percent)
        stand = -> { @cache.fetch(%w[api rate_limit]) { @gh.call("api", "rate_limit") } }
        @budget = PipelineBoard::Budget.new(stand, percent: percent)
        @rest = Hecks::Adapters::GhRest.new(method(:read))
      end

      # A read kept for its seconds; a read that would run is first checked against the budget it
      # spends, and refused as {PipelineBoard::Unavailable} while that budget is nearly spent.
      def read(*args)
        @cache.fetch(args) do
          @budget.check!(args)
          @gh.call(*args)
        end
      end
    end
  end
end
