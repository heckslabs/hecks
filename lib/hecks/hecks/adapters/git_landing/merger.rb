# frozen_string_literal: true

require "tmpdir"
require_relative "../git_worktrees"

module Hecks
  module Adapters
    class GitLanding
      # One landing: a branch merged onto another, fast-forward when it can be and as a merge commit
      # when it cannot, in the worktree that has the target checked out, else in a temporary one.
      #
      # It never forces anything, never pushes, and never settles a conflict: a merge that conflicts
      # is aborted and refused, naming the paths in conflict, with every branch as it was.
      class Merger
        include GitWorktrees

        # @param git [Git] the adapter every git call goes through
        # @param checkout [String] the repository's top level the branch is in
        # @param branch [String] the branch to land
        # @param onto [String] the branch to land it on
        def initialize(git, checkout, branch:, onto:)
          @git = git
          @checkout = checkout
          @branch = ref(branch)
          @onto = ref(onto)
        end

        # @return [Hash{Symbol => Hash}] `outcome:` (`current`, `fast_forwarded` or `merged`),
        #   `checkout:`, `branch:`, `landed:` (the commit the target names now) and `report:`
        # @raise [ConsoleCapture::Failure] when the merge conflicts, or a tree holds
        #   uncommitted work
        def land
          tip = branch_tip(@branch)
          before = branch_tip(@onto)
          return answer("current", before, "#{@branch} is already on #{@onto}") if ancestor?(tip, before)

          host = worktree_on(@onto)
          outcome, landed = host ? integrate(host.path, before) : in_temporary_tree(before)
          answer(outcome, landed, "#{@branch} #{outcome.tr("_", " ")} onto #{@onto} at #{short(landed)}")
        end

        private

        def in_temporary_tree(before)
          Dir.mktmpdir("hecks-landing") do |dir|
            tree = File.join(dir, "tree")
            read("worktree", "add", "--detach", tree, before)
            outcome, landed = integrate(tree, before)
            read("update-ref", "refs/heads/#{@onto}", landed, before)
            [outcome, landed]
          ensure
            @git.capture("worktree", "remove", "--force", tree, chdir: @checkout)
          end
        end

        def integrate(dir, before)
          changed = dirty(dir)
          raise ConsoleCapture::Failure, "#{dir} holds uncommitted work: #{changed.join(", ")}" unless changed.empty?

          outcome = ancestor?(before, branch_tip(@branch)) ? fast_forward(dir) : merge_commit(dir)
          [outcome, read("rev-parse", "HEAD", dir: dir)]
        end

        def fast_forward(dir)
          read("merge", "--ff-only", @branch, dir: dir)
          "fast_forwarded"
        end

        def merge_commit(dir)
          result = @git.capture("merge", "--no-ff", "--no-edit", @branch, chdir: dir)
          return "merged" if result.ok?

          conflicts = @git.capture("diff", "--name-only", "--diff-filter=U", chdir: dir).out.split
          @git.capture("merge", "--abort", chdir: dir)
          raise ConsoleCapture::Failure, "merging #{@branch} into #{@onto} conflicts in #{conflicts.join(", ")}; nothing changed"
        end

        def answer(outcome, landed, report)
          { outcome: { value: outcome }, checkout: { value: @checkout }, branch: { value: @branch },
            landed: { value: landed }, report: { value: report } }
        end
      end
    end
  end
end
