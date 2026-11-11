# frozen_string_literal: true

require_relative "../shell"

module Hecks
  module Adapters
    class ClaudeCleaning
      # Says what `claude rm` would lose in one worktree: files not committed, and commits that no
      # branch on `origin` holds. It reads with `git` and changes nothing.
      class WorktreeCheck
        # @param shell [Shell] runs `git`
        def initialize(shell: Shell.new)
          @shell = shell
        end

        # @param path [String] the worktree's directory
        # @return [String, nil] why removing the session would lose work, or nil when it would not;
        #   a directory that is gone holds nothing
        def reason(path)
          return nil unless File.exist?(path)

          dirty = lines(path, "status", "--porcelain")
          return "its worktree #{path} cannot be read as a git tree" unless dirty

          return "its worktree #{path} has #{dirty.length} uncommitted file(s)" unless dirty.empty?

          unpushed(path)
        end

        # @param path [String] the worktree's directory
        # @return [Integer] the files git lists as changed or untracked and not ignored; ignored
        #   files are not counted. An unreadable tree counts as one file.
        def uncommitted(path)
          lines(path, "status", "--porcelain")&.length || 1
        end

        # @param path [String] the worktree's directory
        # @return [Integer] the commits no branch on `origin` holds; an unreadable tree counts as
        #   one
        def ahead(path)
          lines(path, "rev-list", "HEAD", "--not", "--remotes=origin")&.length || 1
        end

        private

        def unpushed(path)
          ahead = lines(path, "rev-list", "HEAD", "--not", "--remotes=origin")
          return "its worktree #{path} cannot be compared with origin" unless ahead

          ahead.empty? ? nil : "its worktree #{path} has #{ahead.length} commit(s) origin lacks"
        end

        # @return [Array<String>, nil] the lines `git` printed in the worktree, nil when it failed
        def lines(path, *)
          result = @shell.capture("git", "-C", path, *)
          result.ok? ? printed(result.out) : nil
        end

        def printed(text) = text.lines.map(&:strip).reject(&:empty?)
      end
    end
  end
end
