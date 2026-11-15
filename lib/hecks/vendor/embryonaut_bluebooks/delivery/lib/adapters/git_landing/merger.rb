# frozen_string_literal: true

require "tmpdir"
require "hecks/hecks/adapters/git_worktrees"
require_relative "swap"

module Hecks
  module Adapters
    class GitLanding
      # One try at a landing: the commit a branch lands as is built beside the target, always a
      # merge commit made in a temporary tree (never a fast-forward), so one landing is one
      # first-parent commit that can be reverted or bisected alone, then the target is moved to it
      # by a compare-and-swap ({Swap}).
      #
      # It never forces anything, never pushes, and never settles a conflict: a merge that conflicts
      # is aborted and refused, naming the paths in conflict, with every branch as it was. When the
      # target moved while it built, it raises {Swap::Lost} with nothing changed.
      class Merger
        include GitWorktrees

        # @param git [Git] the adapter every git call goes through
        # @param checkout [String] the repository's top level the branch is in
        # @param branch [String] the branch to land
        # @param onto [String] the branch to land it on
        # @param built_on_target [Boolean] land only a branch the target is an ancestor of: a target
        #   the branch is not built on counts as moved, so a finish rebases and asks the gate again
        def initialize(git, checkout, branch:, onto:, built_on_target: false)
          @git = git
          @checkout = checkout
          @branch = ref(branch)
          @onto = ref(onto)
          @built_on_target = built_on_target
        end

        # @return [Hash{Symbol => Hash}] `outcome:` (`current` or `merged`),
        #   `checkout:`, `branch:`, `landed:` (the commit the target names now) and `report:`
        # @raise [Swap::Lost] when the target moved while the landing was built
        # @raise [ConsoleCapture::Failure] when the merge conflicts, or a tree holds
        #   uncommitted work
        def land
          tip = branch_tip(@branch)
          before = branch_tip(@onto)
          return answer("current", before, "#{@branch} is already on #{@onto}") if ancestor?(tip, before)

          outcome, candidate = build(tip, before)
          left = Swap.new(@git, @checkout, onto: @onto).move(before, candidate)
          said = "#{@branch} #{outcome.tr("_", " ")} onto #{@onto} at #{short(candidate)}"
          answer(outcome, candidate, [said, left].compact.join("; "))
        end

        private

        def build(tip, before)
          if @built_on_target && !ancestor?(before, tip)
            raise Swap::Lost, "#{@onto} is at #{short(before)}, which #{@branch} is not built on"
          end

          ["merged", merge_commit(before)]
        end

        # The merge of the branch into the target's commit, made in a detached temporary tree so
        # that no checkout's files are the workbench.
        def merge_commit(before)
          Dir.mktmpdir("hecks-landing") do |dir|
            tree = File.join(dir, "tree")
            read("worktree", "add", "--detach", tree, before)
            merge(tree)
            read("rev-parse", "HEAD", dir: tree)
          ensure
            @git.capture("worktree", "remove", "--force", tree, chdir: @checkout)
          end
        end

        def merge(dir)
          result = @git.capture(*identity(dir), "merge", "--no-ff", "-m", "Merge branch '#{@branch}'", @branch, chdir: dir)
          return if result.ok?

          conflicts = @git.capture("diff", "--name-only", "--diff-filter=U", chdir: dir).out.split
          @git.capture("merge", "--abort", chdir: dir)
          raise ConsoleCapture::Failure, "merging #{@branch} into #{@onto} conflicts in #{conflicts.join(", ")}; nothing changed"
        end

        # A merge commit needs an author. The configured one is used; when a machine has none (a
        # session or a spec with no global identity) the branch tip's author makes it, so a landing
        # never fails for want of one and never invents a name.
        #
        # @return [Array<String>] git's `-c` words, empty when an identity is configured
        def identity(dir)
          return [] if @git.capture("config", "user.email", chdir: dir).out.strip != ""

          name, email = @git.capture("log", "-1", "--format=%an%n%ae", @branch, chdir: dir).out.split("\n")
          ["-c", "user.name=#{name}", "-c", "user.email=#{email}"]
        end

        def answer(outcome, landed, report)
          { outcome: { value: outcome }, checkout: { value: primary.path }, branch: { value: @branch },
            landed: { value: landed }, report: { value: report } }
        end
      end
    end
  end
end
