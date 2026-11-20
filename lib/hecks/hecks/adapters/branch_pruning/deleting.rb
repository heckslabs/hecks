# frozen_string_literal: true

module Hecks
  module Adapters
    class BranchPruning
      # Removes one branch the classifier judged deletable. The branch is judged again first, and
      # it goes with `update-ref -d` naming the tip that was judged, so a commit made in between
      # keeps it. Nothing is removed from a worktree, and the report names the tip so the reflog
      # can bring the branch back.
      class Deleting
        # @param git [Git] the adapter every git call goes through
        # @param checkout [String] the repository's top level
        # @param classifier [Classifier] judges a branch again at the moment of deletion
        def initialize(git, checkout, classifier)
          @git = git
          @checkout = checkout
          @classifier = classifier
        end

        # @param verdict [Verdict] a `:delete` judgment
        # @return [String] a line saying what was removed, or why the branch was kept
        def call(verdict)
          fresh = @classifier.call(verdict.branch)
          unless fresh.action == :delete && fresh.tip == verdict.tip
            return "kept #{verdict.branch}: no longer deletable (#{fresh.reason})"
          end

          remove(verdict)
        end

        private

        def remove(verdict)
          result = @git.capture("update-ref", "-d", "refs/heads/#{verdict.branch}", verdict.tip, chdir: @checkout)
          return "kept #{verdict.branch}: #{result.err.strip}" unless result.ok?

          "deleted #{verdict.branch} (was #{verdict.tip}): #{verdict.reason}"
        end
      end
    end
  end
end
