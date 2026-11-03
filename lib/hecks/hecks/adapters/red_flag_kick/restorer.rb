# frozen_string_literal: true

require "tmpdir"
require_relative "../console_capture"

module Hecks
  module Adapters
    class RedFlagKick
      # Rolls main back to its last green tree as one new commit on a new branch, in a worktree of
      # its own: `git read-tree --reset -u <green>` makes the index and the files the green tree,
      # and the commit records it. History is never rewritten. A restore that cannot be made is
      # abandoned, the worktree and the branch removed and the reason named, so main and the
      # repository are as they were.
      class Restorer
        # The lead of the restore commit's subject.
        SUBJECT = "Restore main to the last green tree"

        # @param git [Git] the adapter git runs through
        # @param checkout [String] a directory in the repository
        def initialize(git, checkout)
          @git = git
          @checkout = checkout
        end

        # @param branch [String] the branch to make from `main`
        # @param green [String] the last green head of main, whose tree is restored
        # @param batch [Array<String>] the commits the restore undoes, newest first
        # @return [String] the worktree the branch is checked out in
        # @raise [ConsoleCapture::Failure] when the worktree or the commit cannot be made
        def restore(branch, green, batch)
          tree = Dir.mktmpdir("hecks-red-kick")
          made = git("worktree", "add", "-q", "-b", branch, tree, "main")
          raise ConsoleCapture::Failure, "git worktree add: #{made.err.strip}" unless made.ok?

          commit(tree, branch, green, batch)
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

        def commit(tree, branch, green, batch)
          done = git("read-tree", "--reset", "-u", green, dir: tree)
          done = git("commit", "-q", "--allow-empty", "-m", message(green, batch), dir: tree) if done.ok?
          return if done.ok?

          tidy(branch, tree)
          raise ConsoleCapture::Failure, "restoring #{green[0, 10]} failed: #{done.err.strip}"
        end

        def message(green, batch)
          "#{SUBJECT} #{green[0, 10]}\n\nCI on main went red. This restores the tree of #{green}, " \
            "the last green head, undoing these commits, newest first: #{batch.join(", ")}."
        end

        def git(*, dir: @checkout) = @git.capture(*, chdir: dir)
      end
    end
  end
end
