# frozen_string_literal: true

require_relative "git_worktrees"

module Hecks
  module Adapters
    # The `Restoring` port's adapter for `Restore`: puts back each changed tracked file whose
    # content is already what `origin/main` holds, so the checkout can take a pull.
    #
    # It restores only a file that loses nothing: a changed file that differs from `origin/main`,
    # an untracked file and a staged change are left as they are and named in the report. It never
    # fetches, commits, pushes or resets.
    class GitRestoration
      include GitWorktrees

      # Accepts the arguments every driven adapter is built with and keeps none of them.
      #
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] unused
      # @param root [String, nil] unused
      def initialize(aggregate: nil, settings: {}, root: nil)
        @git = Git.new
      end

      # Restores the changed files that already match `origin/main`.
      #
      # @param held [Hash] the `Restoration` record: `checkout` (a directory inside the worktree;
      #   the current directory when absent)
      # @return [Hash{Symbol => Hash}] `report:` what was restored and what was kept
      # @raise [ConsoleCapture::Failure] when nothing is changed, or no changed file matches
      def restore(**held)
        settle(held)
        changed = read("diff", "--name-only").lines.map(&:strip)
        raise ConsoleCapture::Failure, "no tracked file is changed here" if changed.empty?

        same, kept = changed.partition { |path| matches_origin?(path) }
        raise ConsoleCapture::Failure, "no changed file matches origin/main; kept #{kept.join(", ")}" if same.empty?

        read("checkout", "--", *same)
        { report: { value: report(same, kept) } }
      end

      private

      # A file matches when the working copy equals its version on `origin/main`.
      def matches_origin?(path) = read("diff", "--name-only", "origin/main", "--", path).empty?

      def report(same, kept)
        text = "restored #{same.size} file(s) that match origin/main"
        kept.empty? ? text : "#{text}; kept #{kept.size} that differ: #{kept.join(", ")}"
      end
    end
  end
end
