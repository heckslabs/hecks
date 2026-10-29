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
