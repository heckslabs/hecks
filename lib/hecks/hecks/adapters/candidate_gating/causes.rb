# frozen_string_literal: true

require "hecks/quality_control/adapters/run_keys"
require_relative "../dispatching/lesson_traps"

module Hecks
  module Adapters
    class CandidateGating
      # The causes of a red candidate, one per group of failed jobs: a job whose name matches a
      # lesson's signature is grouped under that lesson's kind, and any other under its own name
      # with the shard suffix left off, so eight red shards of one suite file one Work item. Each
      # cause names its `red-<cause>` Work item.
      class Causes
        # The suffix a sharded job carries: ` (3)`, `_2_of_3` or ` 2/3`.
        SHARD = %r{(\s*\(\d+\)|_\d+_of_\d+|\s+\d+/\d+)\z}

        # @param jobs [String] the failed jobs, comma separated, as the CI reading lists them
        # @param lessons [Array<Hash>] the lessons `Dispatching::LessonTraps` reads
        def initialize(jobs, lessons: [])
          @jobs = named(jobs)
          @lessons = lessons
        end

        # @return [Hash{String => Array<String>}] each cause to the failed jobs under it
        def grouped
          @jobs.group_by { |job| kind_of(job) || job.sub(SHARD, "") }
        end

        # @param cause [String] a cause from {#grouped}
        # @return [String] the key of its Work item
        def key(cause) = RunKeys.build(cause, cause)

        private

        # The job names in a comma-separated list, trimmed, with no empty one.
        def named(jobs)
          names = jobs.to_s.split(",").map(&:strip)
          names.reject(&:empty?)
        end

        def kind_of(job) = Dispatching::LessonTraps.match(@lessons, job).first
      end
    end
  end
end
