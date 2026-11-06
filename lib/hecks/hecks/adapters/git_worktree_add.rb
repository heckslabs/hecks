# frozen_string_literal: true

require_relative "git_worktrees"
require_relative "git_main_pull"

module Hecks
  module Adapters
    # The `WorktreeAdding` port's adapter for `Worktree`: opens a linked worktree on a new branch
    # cut from
    # `main` (pulled first, see {GitMainPull}), or from a base named, at the path named or under the
    # checkout's `.claude/worktrees`. A base other than `main` is cut as it stands and local `main`
    # is not pulled, so a branch can start from `origin/main` without rewriting local `main`.
    #
    # It never checks out `main` in a worktree, never pushes, and never forces. A branch that
    # already exists is declined by git, and the reason travels back on the record.
    class GitWorktreeAdd
      include GitWorktrees
      include GitMainPull

      # Accepts the arguments every driven adapter is built with and keeps none of them.
      #
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] unused
      # @param root [String, nil] unused
      def initialize(aggregate: nil, settings: {}, root: nil)
        @git = Git.new
      end

      # Opens the worktree, then reads the sha it stands on.
      #
      # @param held [Hash] the `Worktree` record: `checkout` (a directory inside the repository; the
      #   current directory when absent), `branch` (a new branch name), `path` (optional) and `base`
      #   (a ref to cut from, `main` when absent)
      # @return [Hash{Symbol => Hash}] `sha:` the commit it stands on, `report:` where it is
      # @raise [ConsoleCapture::Failure] on a missing branch, a branch named main, a base that is
      #   not a commit, or a directory outside a repository
      def create(**held)
        repo = settle(held)
        branch = branch_named(held)
        base = base_named(held)
        path = plain(held[:path]).to_s.strip
        path = File.join(repo, ".claude", "worktrees", branch) if path.empty?
        pulled = base == "main" ? pull_main : "cut from #{base}; main not pulled"
        read("worktree", "add", "-b", branch, path, base)
        sha = read("rev-parse", "--short", "HEAD", dir: path)
        { path: { value: path }, sha: { value: sha }, report: { value: "opened #{path} on #{branch}; #{pulled}" } }
      end

      # Brings local `main` up to date with `origin/main`: a fast-forward, or a rebase of its
      # unpushed commits when both moved. Refuses a dirty checkout or a rebase in progress.
      #
      # @param held [Hash] the `LinkedTree` record: `checkout` (a directory inside the repository)
      # @return [Hash{Symbol => Hash}] `sha:` where `main` stands, `report:` what was done
      # @raise [ConsoleCapture::Failure] `cannot pull main: ...` with the reason
      def pull(**held)
        settle(held)
        said = pull_main
        { sha: { value: read("rev-parse", "--short", "main") }, report: { value: said } }
      end

      private

      # The ref a worktree is cut from: `main` when none is named, and a ref that resolves to a
      # commit.
      def base_named(held)
        base = plain(held[:base]).to_s.strip
        base = "main" if base.empty?
        ref(base)
        found = @git.capture("rev-parse", "--verify", "--quiet", "#{base}^{commit}", chdir: @checkout)
        raise ConsoleCapture::Failure, "cannot open a worktree from #{base}: it is not a commit" unless found.ok?

        base
      end

      # The branch a worktree is cut on: a name, and never main.
      def branch_named(held)
        branch = plain(held[:branch]).to_s.strip
        raise ConsoleCapture::Failure, "a worktree needs a branch" if branch.empty?
        raise ConsoleCapture::Failure, "a worktree is not opened on main" if branch == "main"

        branch
      end
    end
  end
end
