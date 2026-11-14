# frozen_string_literal: true

require "hecks/hecks/adapters/git"
require "hecks/hecks/adapters/git_worktrees"
require_relative "git_main_pull"

module Hecks
  module Adapters
    # The `Picking` port's adapter for `LinkedTree`: cherry-picks one commit onto the branch a
    # worktree has checked out. A conflict aborts the pick, so the branch is left as it was, and the
    # refusal names every conflicted path. Nothing is resolved silently.
    #
    # It refuses main, a branch checked out in no worktree, a dirty checkout and one in the middle
    # of a rebase or merge. It never forces.
    class GitPick
      include GitWorktrees

      # Accepts the arguments every driven adapter is built with, and a `git` runner a spec may
      # stand in for.
      #
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] unused
      # @param root [String, nil] unused
      # @param git [#capture] the runner `Git` is, a stand-in in a spec
      def initialize(aggregate: nil, settings: {}, root: nil, git: Git.new)
        @git = git
      end

      # Cherry-picks the commit onto the branch's worktree.
      #
      # @param held [Hash] the `LinkedTree` record: `checkout` (a directory inside the repository),
      #   `branch` (a branch other than main) and `commit` (the commit to apply)
      # @return [Hash{Symbol => Hash}] `sha:` the commit the branch stands on, `report:` what was
      #   done
      # @raise [ConsoleCapture::Failure] on a refused request, a dirty checkout, or a conflict
      def apply(**held)
        settle(held)
        branch = named_branch(held)
        commit = ref(plain(held[:commit]).to_s.strip)
        host = hosting(branch)
        refuse_unready(host, branch)
        pick_or_abort(host, branch, commit)
        sha = read("rev-parse", "--short", "HEAD", dir: host.path)
        { sha: { value: sha }, report: { value: "picked #{commit} onto #{branch} at #{sha}" } }
      end

      private

      def named_branch(held)
        branch = plain(held[:branch]).to_s.strip
        raise ConsoleCapture::Failure, "a commit is picked onto a branch by its name" if branch.empty?
        raise ConsoleCapture::Failure, "a commit is never picked onto main" if branch == "main"

        ref(branch)
      end

      # The worktree the branch is checked out in: the only place a commit can be picked onto it.
      def hosting(branch)
        host = worktree_on(branch)
        raise ConsoleCapture::Failure, "cannot pick onto #{branch}: it is checked out in no worktree" unless host

        host
      end

      def refuse_unready(host, branch)
        midway = GitMainPull::MIDWAY.find { |name, _| File.exist?(git_path(host.path, name)) }
        raise ConsoleCapture::Failure, "cannot pick onto #{branch}: its checkout is in the middle of a #{midway.last}" if midway

        changed = read("status", "--porcelain", "--untracked-files=no", dir: host.path)
        raise ConsoleCapture::Failure, "cannot pick onto #{branch}: the checkout has uncommitted changes" unless changed.empty?
      end

      def git_path(dir, name) = read("rev-parse", "--path-format=absolute", "--git-path", name, dir: dir)

      # Picks the commit; a conflict or any other refusal aborts the pick and names the reason.
      def pick_or_abort(host, branch, commit)
        result = @git.capture("cherry-pick", commit, chdir: host.path)
        return if result.ok?

        conflicts = read("diff", "--name-only", "--diff-filter=U", dir: host.path).split("\n")
        @git.capture("cherry-pick", "--abort", chdir: host.path)
        reason = conflicts.empty? ? result.err.strip : "conflicts in #{conflicts.join(", ")}"
        raise ConsoleCapture::Failure, "cannot pick #{commit} onto #{branch}: #{reason}; nothing changed"
      end
    end
  end
end
