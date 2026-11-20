# frozen_string_literal: true

require_relative "reading"
require_relative "branch_guard"

module Hecks
  module Adapters
    class GitTrain
      # Reverts one landing on local main with a new commit (`git revert -m 1`). History is never
      # rewritten and nothing is forced: a revert that conflicts is aborted and refused by name.
      #
      # Reverting a merge leaves its branch's commits held by the branch it was landed on, so
      # rebasing or merging that branch again brings in nothing; the report says how the work
      # lands again.
      class Reverting
        include Reading

        # How reverted work lands again, said of the revert commit the report names.
        LAND_AGAIN = "To land this work again, revert that revert (git revert %<revert>s) and add new commits, " \
                     "or make fresh commits. Never rebase or re-merge the old branch: main already holds its " \
                     "commits, so it brings in nothing."

        # @param git [Git] the adapter every git call goes through
        # @param checkout [String] the repository's top level
        # @param branch [String] the branch the landing is reverted on
        def initialize(git, checkout, branch: "main")
          @git = git
          @checkout = checkout
          @branch = branch
          @guard = BranchGuard.new(git, checkout, branch)
        end

        # @param merge [String] the landing's merge commit, which the branch must hold
        # @param reason [String] why the landing is reverted; the report opens with it
        # @return [Hash{Symbol => String}] `reverted:` the new commit and `report:`
        # @raise [ConsoleCapture::Failure] when the checkout is not on the branch or not clean, the
        #   commit is not a merge the branch holds, or the revert conflicts (it is aborted)
        def revert(merge, reason: "")
          @guard.clean!
          merge = read("rev-parse", "--verify", "#{merge}^{commit}")
          held!(merge)
          result = @git.capture("revert", "-m", "1", "--no-edit", merge, chdir: @checkout)
          refuse!(merge, result) unless result.ok?
          { reverted: @guard.head, report: report(merge, reason.to_s.strip) }
        end

        private

        def held!(merge)
          parents = read("rev-list", "--parents", "-n", "1", merge).split.size - 1
          return if parents > 1 && ancestor?(merge, "refs/heads/#{@branch}")

          raise ConsoleCapture::Failure, "#{short(merge)} is not a landing (a merge) that #{@branch} holds: nothing was reverted"
        end

        def refuse!(merge, result)
          conflicts = read("diff", "--name-only", "--diff-filter=U")
          @git.capture("revert", "--abort", chdir: @checkout)
          why = conflicts.empty? ? "failed" : "conflicts"
          raise ConsoleCapture::Failure, "reverting #{short(merge)} #{why}: #{result.err.strip}; the revert was aborted"
        end

        def report(merge, reason)
          opening = reason.empty? ? "Reverted landing #{short(merge)}" : "#{reason} It was reverted"
          "#{opening} as #{@guard.head}. #{format(LAND_AGAIN, revert: @guard.head)}"
        end
      end
    end
  end
end
