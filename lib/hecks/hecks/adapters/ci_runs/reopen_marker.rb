# frozen_string_literal: true

module Hecks
  module Adapters
    class CiRuns
      # The comments the pipeline leaves on a train pull request it closes and reopens to start its
      # CI. GitHub is the only store that outlives a beat's process, so the comments are the record:
      # one says the reopening began, the other that it finished.
      module ReopenMarker
        # The comment left before the pull request is closed.
        REOPENING = "hecks: closing and reopening to start CI, which never started"

        # The comment left once it is open again.
        REOPENED = "hecks: reopened to start CI"

        module_function

        # @param comments [Array<Hash>, nil] the pull request's `comments`, each with a `body`
        # @return [Boolean] whether the pipeline began a reopening of it, finished or not
        def reopened?(comments) = bodies(comments).any? { |body| body.start_with?(REOPENING, REOPENED) }

        # @param comments [Array<Hash>, nil] the pull request's `comments`
        # @return [Boolean] whether a reopening began and has not finished: the pull request is
        #   closed only for the moment
        def reopening?(comments)
          marks = bodies(comments).select { |body| body.start_with?(REOPENING, REOPENED) }
          marks.last.to_s.start_with?(REOPENING)
        end

        # @param comments [Array<Hash>, nil] the pull request's `comments`
        # @return [Array<String>] their bodies, in order
        def bodies(comments) = Array(comments).map { |comment| comment["body"].to_s }
      end
    end
  end
end
