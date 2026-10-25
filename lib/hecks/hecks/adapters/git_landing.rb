# frozen_string_literal: true

require_relative "git_worktrees"
require_relative "git_landing/merger"

module Hecks
  module Adapters
    # The `Worktrees` port's adapter for `Landing`: merges a worktree's branch onto local `main`,
    # retires a worktree and its branch once they are merged, and lists what is not on `main`.
    #
    # It never pushes, never forces, and never resolves a conflict. Retiring refuses a worktree
    # that holds uncommitted work or a branch with commits `main` lacks, so no unpushed work goes.
    class GitLanding
      include GitWorktrees

      # Accepts the arguments every driven adapter is built with and keeps none of them.
      #
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] unused
      # @param root [String, nil] unused
      def initialize(aggregate: nil, settings: {}, root: nil)
        @git = Git.new
      end

      # Lands a worktree's branch onto another branch (local `main` by default).
      #
      # @param held [Hash] the `Landing` record: `checkout` (a directory inside the worktree; the
      #   current directory when absent), `branch` (its checked-out branch when absent), `onto`
      # @return [Hash{Symbol => Hash}] the answer `Merger#land` describes
      # @raise [ConsoleCapture::Failure] on a conflict, uncommitted work, or no such branch
      def merge(**held)
        settle(held)
        branch = plain(held[:branch]) || current_branch
        onto = plain(held[:onto]) || "main"
        raise ConsoleCapture::Failure, "#{branch} is the branch to land onto" if branch == onto

        refuse_unsaved(branch)
        Merger.new(@git, @checkout, branch: branch, onto: onto).land
      end

      # Removes a linked worktree and deletes its branch, once the branch is on `onto`.
      #
      # @param held [Hash] the `Landing` record: `checkout` (the worktree to remove), `branch`
      #   (its checked-out branch when absent), `onto`
      # @return [Hash{Symbol => Hash}] `outcome:` (`retired`), `checkout:`, `branch:`, `report:`
      # @raise [ConsoleCapture::Failure] when it is the primary worktree, holds uncommitted work,
      #   or its branch has commits `onto` lacks
      def remove(**held)
        settle(held)
        branch = plain(held[:branch]) || current_branch
        onto = plain(held[:onto]) || "main"
        gone = @checkout
        home = primary.path
        refuse_unretirable(branch, onto)
        read("worktree", "remove", gone, dir: home)
        read("branch", "-D", ref(branch), dir: home)
        { outcome: { value: "retired" }, checkout: { value: gone }, branch: { value: branch },
          report: { value: "removed #{gone} and deleted #{branch}, which is on #{onto}" } }
      end

      # The branches whose commits are not on a branch, or that hold uncommitted work.
      #
      # @param held [Hash] `checkout` (any directory in the repository), `onto` (default `main`)
      # @return [Hash{Symbol => String}] `text:` one tab-separated line per branch
      # @raise [Runtime::NotFound] when the checkout is not a repository
      def unlanded(**held)
        settle(held)
        onto = ref(plain(held[:onto]) || "main")
        lines = branches.reject { |name| name == onto }.filter_map { |name| unlanded_line(name, onto) }
        { text: lines.empty? ? "everything is on #{onto}\n" : "#{lines.join("\n")}\n" }
      rescue ConsoleCapture::Failure => e
        raise Runtime::NotFound, e.message
      end

      private

      def refuse_unsaved(branch)
        tree = worktree_on(branch)
        changed = tree ? dirty(tree.path) : []
        raise ConsoleCapture::Failure, "#{tree.path} holds uncommitted work: #{changed.join(", ")}" unless changed.empty?
      end

      def refuse_unretirable(branch, onto)
        raise ConsoleCapture::Failure, "#{@checkout} is the primary worktree" if @checkout == primary.path

        refuse_unsaved(branch)
        behind = count("#{ref(onto)}..#{ref(branch)}")
        raise ConsoleCapture::Failure, "#{branch} has #{behind} commit(s) not on #{onto}" if behind.positive?
      end

      def branches = read("for-each-ref", "--format=%(refname:short)", "refs/heads").split("\n")

      def unlanded_line(name, onto)
        ahead = count("#{onto}..#{name}")
        tree = worktree_on(name)
        changed = tree ? dirty(tree.path).size : 0
        return nil if ahead.zero? && changed.zero?

        [name, "#{ahead} commit(s) not on #{onto}", tree&.path || "no worktree", "#{changed} uncommitted"].join("\t")
      end
    end
  end
end
