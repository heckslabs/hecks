# frozen_string_literal: true

require "tmpdir"
require_relative "../console_capture"

module Hecks
  module Adapters
    class RedFlagKick
      # Reverts a batch of commits on a new branch, in a worktree of its own, newest first; a merge
      # is reverted against its first parent. A revert that conflicts is abandoned, the worktree and
      # the branch removed, and the conflict named, so main and the repository are as they were.
      class Reverter
        # @param git [Git] the adapter git runs through
        # @param checkout [String] a directory in the repository
        def initialize(git, checkout)
          @git = git
          @checkout = checkout
        end

        # @param branch [String] the branch to make from `main`
        # @param batch [Array<String>] the commits to revert, newest first
        # @return [String] the worktree the branch is checked out in
        # @raise [ConsoleCapture::Failure] when the worktree cannot be made or a revert conflicts
        def revert(branch, batch)
          tree = Dir.mktmpdir("hecks-red-kick")
          made = git("worktree", "add", "-q", "-b", branch, tree, "main")
          raise ConsoleCapture::Failure, "git worktree add: #{made.err.strip}" unless made.ok?

          batch.each { |sha| revert_one(tree, branch, sha) }
          tree
        end

        # Removes the worktree and the branch.
        #
        # @param branch [String] the branch to delete
        # @param tree [String] the worktree to remove
        # @return [void]
        def tidy(branch, tree)
          git("worktree", "remove", "--force", tree)
          git("branch", "-D", branch)
        end

        private

        def revert_one(tree, branch, sha)
          done = git("revert", "--no-edit", *(merge?(sha) ? ["-m", "1"] : []), sha, dir: tree)
          return if done.ok?

          git("revert", "--abort", dir: tree)
          tidy(branch, tree)
          raise ConsoleCapture::Failure, "reverting #{sha[0, 10]} conflicts: #{done.err.strip}"
        end

        # Whether the commit has more than one parent.
        def merge?(sha)
          parents = git("rev-list", "--parents", "-n", "1", sha).out
          parents.split.size > 2
        end

        def git(*, dir: @checkout) = @git.capture(*, chdir: dir)
      end
    end
  end
end
