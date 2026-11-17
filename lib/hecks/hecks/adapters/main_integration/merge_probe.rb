# frozen_string_literal: true

require_relative "impacted_check"
require_relative "failure_log"

module Hecks
  module Adapters
    class MainIntegration
      # One probe of the search for the first bad merge: a clean copy of the merge, in which the
      # specs the merge's own paths touch run, as a verification's impacted-spec check runs
      # them. It runs outside any verification's copy, one after another, so the copy's turn
      # (`CopyLock`) is free; the run takes a heavy-job place as the check does.
      class MergeProbe
        # @param repository [Repository] the repository the merges are in
        # @param impacted [#call, nil] stands in for the impacted-spec run ({ImpactedCheck})
        def initialize(repository, impacted: nil)
          @repository = repository
          @impacted = impacted
        end

        # @param merge [Hash] `sha:` and `paths:` of a landing
        # @return [Array(Boolean, Hash)] whether its specs passed, and the failing spec and
        #   example it printed when they did not
        def call(merge)
          parent = @repository.commit("#{merge[:sha]}^1")
          @repository.clean_copy(merge[:sha]) do |directory|
            ok, output = ImpactedCheck.new(directory, merge[:paths], parent, run: @impacted).call
            [ok, (FailureLog.finding(output) unless ok)]
          end
        end

        # @param commit [String] a commit that holds none of the merge, as the last verified one
        # @param merge [Hash] `paths:` of a landing
        # @return [Boolean] whether the specs the merge's paths touch are red at the commit: a spec
        #   that is red there too is not the merge's doing
        def red_at?(commit, merge)
          @repository.clean_copy(commit) do |directory|
            ok, = ImpactedCheck.new(directory, merge[:paths], commit, run: @impacted).call
            !ok
          end
        end
      end
    end
  end
end
