# frozen_string_literal: true

require_relative "../git_worktrees"

module Hecks
  module Adapters
    class GitLanding
      # What a landing leaves behind: the linked worktree it landed from and that worktree's branch.
      #
      # It removes both only when the worktree is a linked one (never the main checkout), holds no
      # uncommitted work, and its branch has no commit the target lacks. Otherwise it keeps
      # everything and says why.
      class Tidy
        include GitWorktrees

        # @param git [Git] the adapter every git call goes through
        # @param checkout [String] the repository's top level
        # @param branch [String] the landed branch
        # @param onto [String] the branch it was landed on
        def initialize(git, checkout, branch:, onto:)
          @git = git
          @checkout = checkout
          @branch = ref(branch)
          @onto = ref(onto)
        end

        # @return [String] a sentence saying what was removed, or why nothing was
        def call
          kept = reason_to_keep
          return "kept #{@branch}: #{kept}" if kept

          path = worktree_on(@branch).path
          read("worktree", "remove", path, dir: primary.path)
          read("branch", "-D", @branch, dir: primary.path)
          "removed #{path} and deleted #{@branch}"
        end

        private

        def reason_to_keep
          tree = worktree_on(@branch)
          return "no linked worktree has it checked out" unless tree
          return "its worktree is the main checkout" if tree.path == primary.path

          changed = dirty(tree.path)
          return "#{tree.path} holds uncommitted work: #{changed.join(", ")}" unless changed.empty?

          behind = count("#{@onto}..#{@branch}")
          "it has #{behind} commit(s) not on #{@onto}" if behind.positive?
        end
      end
    end
  end
end
