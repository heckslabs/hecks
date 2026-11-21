# frozen_string_literal: true

require_relative "../git_refs"

module Hecks
  module Adapters
    class BranchPruning
      # What the pruning reads of a repository, and nothing it writes: the local branches, the ones
      # a worktree holds, and for one branch what `main` lacks of it. Every branch name is checked
      # against `GitRefs::REF_PATTERN` first, so a name cannot carry a flag.
      class Reading
        WORKTREE_BRANCH = %r{\Abranch refs/heads/(.+)}
        UNLANDED_COMMIT = /\A\+ (\h+)/

        # @param git [Git] the adapter every git call goes through
        # @param checkout [String] the repository's top level
        # @param onto [String] the branch whose content counts as landed
        def initialize(git, checkout, onto: "main")
          @git = git
          @checkout = checkout
          @onto = onto
        end

        # @return [Array<String>] the local branches that are safe to name to git
        def branches
          lines("for-each-ref", "--format=%(refname:short)", "refs/heads").grep(GitRefs::REF_PATTERN)
        end

        # @return [Array<String>] the branches any worktree has checked out
        def held
          lines("worktree", "list", "--porcelain").filter_map { |line| line[WORKTREE_BRANCH, 1] }
        end

        # @return [String] the commit a branch names
        def tip(branch) = lines("rev-parse", "--verify", "refs/heads/#{branch}^{commit}").first

        # @return [Array<String>] the commits of a branch with no patch-equivalent in `onto`
        def ahead(branch)
          lines("cherry", @onto, branch).filter_map { |line| line[UNLANDED_COMMIT, 1] }
        end

        # @return [Boolean] whether `onto` contains the commit
        def on_main?(sha) = @git.capture("merge-base", "--is-ancestor", sha, @onto, chdir: @checkout).ok?

        # @return [Array<String>] one line per commit `onto` lacks of the branch
        def commits(branch) = lines("log", "--format=%h %s", "#{@onto}..#{branch}")

        # @return [String] what the branch changes against `onto`, as git summarises it
        def diffstat(branch) = lines("diff", "--shortstat", "#{@onto}...#{branch}").first.to_s.strip

        private

        def lines(*) = words(@git.capture(*, chdir: @checkout).out)

        def words(text) = text.lines.map(&:strip).reject(&:empty?)
      end
    end
  end
end
