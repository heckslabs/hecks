# frozen_string_literal: true

require_relative "../rust_build"

module Hecks
  module RustBuild
    # What git says about a checkout's worktrees, for deciding whose build output may go.
    module Worktrees
      # A worktree's record in `git worktree list --porcelain` ends at a blank line.
      RECORD_BREAK = /\n\n+/

      PATH_LINE = /^worktree (.+)$/

      BRANCH_LINE = %r{^branch refs/heads/(.+)$}

      # A locked worktree belongs to a live agent session.
      LOCKED_LINE = /^locked/

      module_function

      # @param root [String] any directory in the repository
      # @return [String] git's porcelain listing of every worktree
      def listing(root)
        IO.popen(["git", "-C", root, "worktree", "list", "--porcelain"], &:read)
      end

      # @param listing [String] the porcelain listing
      # @return [Array<String>] every worktree's path; the main checkout comes first
      def paths(listing)
        listing.scan(PATH_LINE).flatten
      end

      # The linked worktrees whose branch is already merged into `main`. The main checkout, the
      # worktree `running` sits in and any locked worktree are never named.
      #
      # @param listing [String] the porcelain listing
      # @param running [String] the directory this process runs from
      # @return [Array<String>] worktree paths
      def merged(listing, running:)
        main = paths(listing).first
        landed = merged_branches(main)
        listing.split(RECORD_BREAK).filter_map do |record|
          path = record[PATH_LINE, 1]
          path if landed.include?(record[BRANCH_LINE, 1]) && path != main && free?(record, path, running)
        end
      end

      # @return [Array<String>] the branches merged into the main checkout's `main`
      def merged_branches(main)
        command = ["git", "-C", main, "branch", "--format=%(refname:short)", "--merged", "main"]
        IO.popen(command, &:read).split
      end

      # @return [Boolean] whether no live session holds the worktree
      def free?(record, path, running)
        !record.match?(LOCKED_LINE) && !running.start_with?(path)
      end
    end
  end
end
