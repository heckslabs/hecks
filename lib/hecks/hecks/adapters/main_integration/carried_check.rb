# frozen_string_literal: true

require_relative "../git"
require_relative "../console_capture"

module Hecks
  module Adapters
    class MainIntegration
      # Whether `origin/main` already holds a landed commit, so verifying it answers nothing. It
      # holds it when the commit is an ancestor of `origin/main`: a train merges as a merge commit,
      # so every commit it carried keeps its sha there. Reads `origin/main` as last fetched;
      # `Repository#refresh` fetches.
      class CarriedCheck
        REMOTE_MAIN = "origin/main"

        # @param checkout [String] a directory inside the repository
        def initialize(checkout)
          @checkout = checkout
          @git = Git.new
        end

        # @param landed [String] the full commit a run landed
        # @return [String, nil] which test matched; nil when `origin/main` as fetched does not hold
        #   it (or does not exist)
        def by(landed)
          return nil unless @git.capture("rev-parse", "--verify", "--quiet", REMOTE_MAIN, chdir: @checkout).ok?

          "is contained in #{REMOTE_MAIN}" if ancestor?(landed)
        end

        # @param landed [String] the full commit a run landed
        # @return [String, nil] as `by`; nil too when git cannot place the commit in this checkout
        def by_known(landed)
          by(landed)
        rescue ConsoleCapture::Failure
          nil
        end

        private

        def ancestor?(sha) = @git.capture("merge-base", "--is-ancestor", sha, REMOTE_MAIN, chdir: @checkout).ok?
      end
    end
  end
end
