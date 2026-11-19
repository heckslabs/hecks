# frozen_string_literal: true

require_relative "relatedness"

module Hecks
  module Adapters
    class CiRuns
      # The facts a decision to rerun one failed job stands on: how many jobs failed, the id of the
      # one that did when only one did, the failing examples, and whether the failing specs touch
      # the files the pull request changed. It measures; the TrainPr policies decide.
      class RerunFacts
        # The job named when not exactly one listed job failed: a word, since the record needs one.
        NO_JOB = "none"

        # @param runner [#call] takes `(argv, chdir:)` and answers `[ok, output]`
        # @param checkout [String] the directory `gh` runs in, whose `spec/` the map reads
        def initialize(runner, checkout)
          @runner = runner
          @checkout = checkout
        end

        # @param pull [Hash] the red pull request, with its `number`
        # @param jobs [Array<FailedJobs::Job>] the failed jobs of the attempt
        # @param specs [Array<String>] the spec files the failed jobs name
        # @return [Hash{Symbol => Object}] `failed_jobs`, `job`, `examples` and `related`
        def read(pull, jobs, specs)
          job = jobs.one? && jobs.first.id ? jobs.first.id.to_s : NO_JOB
          { failed_jobs: jobs.size, job: job, examples: jobs.flat_map(&:examples).uniq.join(","),
            related: Relatedness.new(@runner, @checkout).judge(pull["number"].to_s, specs) }
        end
      end
    end
  end
end
