# frozen_string_literal: true

require_relative "../shell"

module Hecks
  module Adapters
    class Dispatching
      # Where the repository's own checkout is, found from any worktree of it: the one place a
      # command resolves the checkout it stands in, so a path argument is an override and never a
      # requirement.
      #
      # A session that starts work items works in the main checkout: the reviews, red flags and
      # run records are stored there, and a worktree belongs to one work item. A roll heard by a
      # worktree's process therefore names the main checkout, never its own directory.
      module Checkout
        # The line `git worktree list --porcelain` opens a worktree's block with.
        WORKTREE_LINE = /\Aworktree (.+)\z/

        # The blank line between two worktrees' blocks.
        BLOCK_BREAK = /\n\n+/

        # The line naming the branch a worktree has checked out.
        BRANCH_LINE = %r{\Abranch refs/heads/(.+)\z}

        # @param directory [String] any directory of the repository, a linked worktree included
        # @return [String] the main checkout's absolute path; `directory` itself when git cannot
        #   name one
        def self.main(directory)
          common = git(directory, "rev-parse", "--path-format=absolute", "--git-common-dir")
          return directory unless common.ok?

          path = common.out.strip
          File.basename(path) == ".git" ? File.dirname(path) : path
        end

        # The worktree that has a branch checked out, so a command acting on `main` from a linked
        # worktree acts on the checkout `main` stands in.
        #
        # @param branch [String] a local branch name
        # @param directory [String] any directory of the repository
        # @return [String] that worktree's path; the main checkout when no worktree holds the branch
        def self.holding(branch, directory)
          listed = git(directory, "worktree", "list", "--porcelain")
          found = listed.ok? && worktrees(listed.out).find { |_path, held| held == branch }
          found ? found.first : main(directory)
        end

        # @param porcelain [String] `git worktree list --porcelain` output
        # @return [Array<Array(String, String)>] each worktree's path and the branch it holds
        def self.worktrees(porcelain)
          porcelain.split(BLOCK_BREAK).map do |block|
            lines = block.lines.map(&:strip)
            [lines.filter_map { |line| line[WORKTREE_LINE, 1] }.first, lines.filter_map { |line| line[BRANCH_LINE, 1] }.first]
          end
        end

        # @return [Shell::Result] what git answered, run in the directory
        def self.git(directory, *) = Shell.new.capture("git", *, chdir: directory)
      end
    end
  end
end
