# frozen_string_literal: true

require "json"
require "time"
require_relative "cache"
require_relative "pipeline_github/settled_counts"
require_relative "pipeline_github/runs"
require_relative "../../cache_dir"

module Hecks
  module Adapters
    # The `GitHub` port's adapter: answers `CiRuns` and `SlowestJobs` with CI as GitHub reports it,
    # read through `gh run list` and `gh run view`. It only reads, and keeps every read for a few
    # seconds.
    class PipelineGitHub
      include PipelineBoard::PipelineRuns

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

      # @return [Hash, nil] the newest `v` release: `tag`, `published` and `published_at`
      # @raise [PipelineBoard::Unavailable] when `gh` cannot answer
      def latest_release
        listed = read("release", "list", "--limit", "20", "--json", "tagName,isDraft,isPrerelease,publishedAt")
        found = listed.find { |release| release["tagName"].to_s.match?(VERSION_TAG) }
        raise PipelineBoard::Unavailable, "no v release found" unless found

        { tag: found["tagName"], published: !found["isDraft"], published_at: found["publishedAt"] }
      end

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

      def read(*args) = @cache.fetch(args) { @gh.call(*args) }
    end
  end
end
