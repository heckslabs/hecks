# frozen_string_literal: true

require "json"
require "hecks/ci_speed/adapters/ci_reader"

module Hecks
  module Adapters
    # The `Runner` port's adapter for GitHub Actions: answers `Build`'s `Reading` and `CriticalPath`
    # queries from the run `gh` reports. A build id is a GitHub run id.
    #
    # GitHub does not report a job's `needs`, so the path here is the jobs ordered by wall time with
    # the slowest first: the longest pole, which bounds the real chain from below. The needs edges
    # the bluebook declares as policies are what a projection would add.
    class CiRunner
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] unused
      # @param root [String, nil] the checkout `gh` runs in; this repository when nil
      def initialize(aggregate: nil, settings: {}, root: nil)
        @reader = CiReader.new(root: root)
      end

      # @param build [Hash, String, Integer] the run to read
      # @return [Hash] `text:` the run's commit, wall seconds, conclusion, cache state and jobs
      def reading(build:)
        @reader.reading(run_id: build)
      end

      # Answers `Head`'s `Check`: remote CI's verdict on one commit of a repository's main.
      #
      # @param commit [Hash, String] the commit
      # @param branch [Hash, String] the branch the commit is on; only `main` is judged
      # @param repo [Hash, String] `owner/name` of the repository
      # @return [Hash] `commit`, `branch`, `repo`, `color` and `failing_jobs`, as the event
      #   takes them
      # @raise [Runtime::GivenNotMet] when remote CI has no settled verdict for the commit
      def check(commit:, branch:, repo:)
        verdict = JSON.parse(@reader.head(commit: commit, repo: repo).fetch(:text))
        { commit: { value: verdict.fetch("commit") }, branch: { value: named(branch) },
          repo: { value: named(repo) }, color: { value: verdict.fetch("color") },
          failing_jobs: { value: verdict.fetch("failing_jobs") } }
      end

      # @return [String] the value a named or bare argument carries
      def named(value) = value.is_a?(Hash) ? value.values.first.to_s : value.to_s

      # @param build [Hash, String, Integer] the run to read
      # @return [Hash] `text:` the run's jobs, the slowest first, and the slowest's seconds
      def critical_path(build:)
        document = JSON.parse(reading(build: build).fetch(:text))
        path = document.fetch("jobs").sort_by { |job| -job.fetch("seconds") }
        { text: JSON.generate(path: path, longest_seconds: path.first&.fetch("seconds")) }
      end
    end
  end
end
