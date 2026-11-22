# frozen_string_literal: true

require_relative "../console_capture"
require_relative "trailer_cutoff"

module Hecks
  module Adapters
    class MainIntegration
      # What a boarding refuses when a commit does not say who made it: every non-merge commit in
      # the range origin/main does not hold must carry a `Hecks-Run` trailer, and unless the run is
      # `owner` a `Hecks-Work` trailer too. A merge is exempt, and so is any commit authored before
      # the {TrailerCutoff}, or in a tree that does not hold the hook that writes the trailers, so
      # history and in-flight branches from before the export are never asked for them. Each
      # refusal names the commit and the missing trailer.
      class TrailerGuard
        # The run a human's commit carries, which needs no work item.
        OWNER = "owner"

        # @param repository [Repository] the checkout the range is read in
        def initialize(repository)
          @repository = repository
        end

        # @param base [String] the commit the remote holds
        # @param tip [String] the commit a boarding would push
        # @return [void]
        # @raise [ConsoleCapture::Failure] naming the first commit missing a trailer
        def check!(base, tip)
          cutoff = TrailerCutoff.new(@repository).at(tip)
          return unless cutoff

          @repository.authored(base, tip).each do |commit|
            next if commit[:time] < cutoff

            missing = missing_trailer(commit)
            refuse!(commit, missing) if missing
          end
        end

        private

        def missing_trailer(commit)
          return "Hecks-Run" if commit[:run].empty?

          "Hecks-Work" if commit[:work].empty? && commit[:run] != OWNER
        end

        def refuse!(commit, trailer)
          raise ConsoleCapture::Failure,
                "boarding refused: commit #{commit[:sha][0, 10]} (#{commit[:subject]}) has no #{trailer} trailer; " \
                "amend it, or rebase with `git rebase --exec` to add it"
        end
      end
    end
  end
end
