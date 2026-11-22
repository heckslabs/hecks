# frozen_string_literal: true

module Hecks
  module Adapters
    class MainIntegration
      # From when a commit is asked to name its run: the moment held in `.githooks/trailers_from`,
      # in epoch seconds, read from the commit a range ends at. A repository asks nothing of any
      # commit until that file exists and its commit-msg hook writes the trailers, so a branch
      # whose tree has no such hook, and every commit authored before the moment, is never asked.
      # Boarding's {TrailerGuard} and the landing's refusal both read the moment here.
      class TrailerCutoff
        # The file that holds the moment, in epoch seconds.
        FILE = ".githooks/trailers_from"

        # What a stored moment looks like: digits alone.
        EPOCH_SECONDS = /\A\d+\z/

        # The hook whose presence says a tree writes the trailers.
        HOOK = ".githooks/commit-msg"

        # @param repository [Repository] the checkout the commit is read in
        def initialize(repository)
          @repository = repository
        end

        # @param tip [String] the commit a range ends at
        # @return [Integer, nil] the epoch second commits are asked from, nil when none is asked
        def at(tip)
          return unless @repository.file_at(tip, HOOK).to_s.include?("Hecks-Run")

          text = @repository.file_at(tip, FILE).to_s.strip
          Integer(text, 10) if text.match?(EPOCH_SECONDS)
        end
      end
    end
  end
end
