# frozen_string_literal: true

module Hecks
  module Adapters
    class BranchPruning
      # What the pruning decided about one branch.
      #
      # @!attribute [r] branch
      #   @return [String] the local branch
      # @!attribute [r] action
      #   @return [Symbol] `:delete`, `:keep`, `:replan` (a planned item) or `:file` (no item)
      # @!attribute [r] reason
      #   @return [String] why, in a sentence
      # @!attribute [r] tip
      #   @return [String, nil] the commit the branch named when it was judged
      # @!attribute [r] filing
      #   @return [Hash, nil] `title:` and `detail:` of the work item to file
      Verdict = Struct.new(:branch, :action, :reason, :tip, :filing) do
        # @return [String] one line for a report
        def line = "#{action} #{branch}#{" (#{tip[0, 12]})" if tip}: #{reason}"
      end
    end
  end
end
