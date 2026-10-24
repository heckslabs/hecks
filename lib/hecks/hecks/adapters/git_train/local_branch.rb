# frozen_string_literal: true

require_relative "reading"

module Hecks
  module Adapters
    class GitTrain
      # The local branch after a push: brought forward to the pushed commit when nothing would be
      # lost by it, so the next merge into it starts from what the remote holds.
      #
      # A branch checked out in a worktree with uncommitted changes, or one that took new commits
      # while the push ran, is left where it is: the next boarding carries those commits.
      class LocalBranch
        include Reading

        # @param git [Git] the adapter every git call goes through
        # @param checkout [String] the repository's top level
        # @param branch [String] the local branch
        def initialize(git, checkout, branch)
          @git = git
          @checkout = checkout
          @branch = branch
        end

        # Brings the branch forward to the pushed commit where that is safe.
        #
        # @param pushed [String] the commit the push took to the remote
        # @return [String] what became of the local branch, as a clause of the report
        def catch_up(pushed)
          local = read("rev-parse", "refs/heads/#{@branch}")
          return "local #{@branch} is there too" if local == pushed
          return "local #{@branch} took new commits meanwhile; the next boarding carries them" unless ancestor?(local, pushed)

          forward(pushed, local, checked_out_in)
        end

        private

        def forward(pushed, local, worktree)
          return update(pushed, local) unless worktree
          return "local #{@branch} has uncommitted changes in #{worktree}; it is left behind" unless clean?(worktree)

          read("merge", "--quiet", "--ff-only", pushed, dir: worktree)
          "local #{@branch} moved forward in #{worktree}"
        end

        def update(pushed, local)
          read("update-ref", "refs/heads/#{@branch}", pushed, local)
          "local #{@branch} moved forward"
        end

        def clean?(worktree) = read("status", "--porcelain", "--untracked-files=no", dir: worktree).empty?

        # The worktree that has the branch checked out, if any.
        def checked_out_in
          blocks = read("worktree", "list", "--porcelain").split("\n\n")
          held = blocks.find { |block| block.lines.map(&:chomp).include?("branch refs/heads/#{@branch}") }
          held && worktree_path(held)
        end

        # The path a `git worktree list --porcelain` block opens with.
        def worktree_path(block)
          first = block.lines.first
          first.delete_prefix("worktree ").strip
        end
      end
    end
  end
end
