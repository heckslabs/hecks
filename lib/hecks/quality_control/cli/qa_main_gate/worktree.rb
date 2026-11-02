# frozen_string_literal: true

require "fileutils"
require "open3"
require "tmpdir"

module Hecks
  module QualityControlCli
    class QaMainGate
      # A temporary git worktree, made for one block and removed when it returns, so a gate or a fix
      # never
      # runs in the owner's checkout.
      module Worktree
        # Raised when a git command the worktree needs fails.
        class Failed < StandardError; end

        module_function

        # @param root [String] the repository the worktree belongs to
        # @param ref [String] the commit the worktree starts at
        # @param branch [String, nil] a new branch checked out in it; nil leaves head detached
        # @yieldparam dir [String] the worktree's directory
        # @return [Object] whatever the block returns
        def with(root:, ref:, branch: nil)
          dir = Dir.mktmpdir("hecks-qa-worktree-")
          git!(root, "worktree", "add", *(branch ? ["-b", branch] : ["--detach"]), dir, ref)
          yield dir
        ensure
          remove(root, dir) if dir
        end

        # @return [String] the output of one git command, stripped
        # @raise [Failed] when git exits non-zero
        def git!(root, *argv)
          output, status = Open3.capture2e("git", "-C", root, *argv)
          raise Failed, "git #{argv.join(" ")} failed: #{output.strip}" unless status.success?

          output.strip
        end

        # @return [Boolean] whether git exited 0
        def git?(root, *argv)
          _, status = Open3.capture2e("git", "-C", root, *argv)
          status.success?
        end

        # Removes a worktree and its directory. Nothing is answered: a removal that fails leaves the
        # directory for `git worktree prune` to report.
        def remove(root, dir)
          try(root, "worktree", "remove", "--force", dir)
          try(root, "worktree", "prune")
          FileUtils.rm_rf(dir)
        end

        # Runs one git command and answers nothing, for the commands whose failure is not a refusal.
        def try(root, *argv)
          Open3.capture2e("git", "-C", root, *argv)
          nil
        end
      end
    end
  end
end
