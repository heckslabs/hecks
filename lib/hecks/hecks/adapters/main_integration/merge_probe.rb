# frozen_string_literal: true

require_relative "spec_probe"
require_relative "failure_log"

module Hecks
  module Adapters
    class MainIntegration
      # One probe of the search for the first bad merge: the specs the failed verification named,
      # run in a clean copy of the merge. A probe tests the failure itself, so its answer is red
      # from the merge that breaks the specs onward, the order a binary search needs. It runs
      # outside any verification's copy, one after another, so the copy's turn (`CopyLock`) is free.
      class MergeProbe
        # @param repository [Repository] the repository the merges are in
        # @param failing [Array<String>] the spec files the failed verification named
        # @param runner [#call, nil] stands in for {SpecProbe}: given the copy's directory and the
        #   spec files, it returns, or raises `ConsoleCapture::Failure` when one is red
        def initialize(repository, failing:, runner: nil)
          @repository = repository
          @failing = failing
          @runner = runner || SpecProbe.new
        end

        # @param merge [Hash] `sha:` of a landing
        # @return [Array(Boolean, Hash)] whether the failing specs passed at the merge, and the
        #   failing spec and example they printed when they did not
        def call(merge)
          @repository.clean_copy(merge[:sha]) { |directory| run(directory) }
        end

        # @param commit [String] a commit that holds none of the merges, as the last verified one
        # @return [Boolean] whether the failing specs are red at the commit: red there too means
        #   no merge of the range is to blame
        def red_at?(commit)
          @repository.clean_copy(commit) { |directory| !run(directory).first }
        end

        private

        def run(directory)
          @runner.call(directory, @failing)
          [true, nil]
        rescue ConsoleCapture::Failure => e
          [false, finding(e.message)]
        end

        def finding(message)
          { spec: FailureLog.specs(message).first || @failing.first, example: FailureLog.finding(message)[:example] }.compact
        end
      end
    end
  end
end
