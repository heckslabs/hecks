# frozen_string_literal: true

require_relative "../git"

module Hecks
  module Adapters
    class MainIntegration
      # What a search for a first bad merge reads of a repository's history beyond its landings:
      # which merges a range's reverts undid, a merge's first parent, and a file as a commit holds
      # it. Reads only.
      class History
        # The line `git revert` writes into its commit's message, naming the commit it undid.
        REVERTED = /^This reverts commit ([0-9a-f]{7,40})/

        # @param checkout [String] a directory inside the repository
        def initialize(checkout)
          @checkout = checkout
          @git = Git.new
        end

        # @param base [String] the commit the range starts after
        # @param tip [String] the commit it ends at
        # @return [Array<String>] the commits the range's first-parent reverts say they undid
        def reverted(base, tip)
          capture("log", "--first-parent", "--format=%B%x1e", "#{base}..#{tip}").to_s.scan(REVERTED).flatten
        end

        # @param sha [String] a commit
        # @return [String, nil] its first parent, nil when it has none
        def first_parent(sha) = capture("rev-parse", "--verify", "--quiet", "#{sha}^1^{commit}")&.strip

        # @param commit [String] a commit
        # @param path [String] a file's path from the repository's top level
        # @return [String, nil] the file as the commit holds it, nil when it holds none
        def file_at(commit, path) = capture("show", "#{commit}:#{path}")

        private

        def capture(*)
          done = @git.capture(*, chdir: @checkout)
          done.ok? ? done.out : nil
        end
      end
    end
  end
end
