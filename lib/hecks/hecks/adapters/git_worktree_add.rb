# frozen_string_literal: true

require_relative "git_worktrees"

module Hecks
  module Adapters
    # The `WorktreeAdding` port's adapter for `Worktree`: opens a linked worktree on a new branch cut from
    # `main`, at the path named or under the checkout's `.claude/worktrees`.
    #
    # It never checks out `main` in a worktree, never pushes, and never forces. A branch that already exists
    # is declined by git, and the reason travels back on the record.
    class GitWorktreeAdd
      include GitWorktrees

      # Accepts the arguments every driven adapter is built with and keeps none of them.
      #
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] unused
      # @param root [String, nil] unused
      def initialize(aggregate: nil, settings: {}, root: nil)
        @git = Git.new
      end

      # Opens the worktree, then reads the sha it stands on.
      #
      # @param held [Hash] the `Worktree` record: `checkout` (a directory inside the repository; the current
      #   directory when absent), `branch` (a new branch name), and `path` (optional)
      # @return [Hash{Symbol => Hash}] `sha:` the commit it stands on, `report:` where it is
      # @raise [ConsoleCapture::Failure] on a missing branch, a branch named main, or a directory outside a repository
      def create(**held)
        repo = settle(held)
        branch = branch_named(held)
        path = plain(held[:path]).to_s.strip
        path = File.join(repo, ".claude", "worktrees", branch) if path.empty?
        read("worktree", "add", "-b", branch, path, "main")
        sha = read("rev-parse", "--short", "HEAD", dir: path)
        { path: { value: path }, sha: { value: sha }, report: { value: "opened #{path} on #{branch}" } }
      end

      private

      # The branch a worktree is cut on: a name, and never main.
      def branch_named(held)
        branch = plain(held[:branch]).to_s.strip
        raise ConsoleCapture::Failure, "a worktree needs a branch" if branch.empty?
        raise ConsoleCapture::Failure, "a worktree is not opened on main" if branch == "main"

        branch
      end
    end
  end
end
