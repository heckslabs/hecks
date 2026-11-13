# frozen_string_literal: true

require "hecks/hecks/adapters/git_worktrees"
require_relative "git_main_pull/carried"
require_relative "git_main_pull/nowhere"
require_relative "git_main_pull/replay"

module Hecks
  module Adapters
    # Bringing local `main` up to date with `origin/main`: the one operation `LinkedTree.PullMain`
    # is, and that `LinkedTree.Add`, `Landing.Land` and `Landing.Finish` lean on, so a branch is
    # never cut or landed from a stale base.
    #
    # One fetch, then a fast-forward when local `main` is behind, or a rebase of its unpushed
    # commits (merge commits kept) when both moved. It never forces, never pushes, never discards
    # a commit and never merges onto `main`. A repository without an `origin` (or with no
    # `origin/main`) has nothing to be behind, and the answer says so.
    #
    # A squash-merged train is rebased past (`Carried`); `main` checked out nowhere is `Nowhere`.
    # An includer has the `GitWorktrees` helpers and sets `@git`.
    module GitMainPull
      include Carried
      include Nowhere
      include Replay

      REMOTE_MAIN = "origin/main"

      # The files git keeps while a rebase or merge is unfinished, and what each is called.
      MIDWAY = { "rebase-merge" => "rebase", "rebase-apply" => "rebase", "MERGE_HEAD" => "merge" }.freeze

      private

      # @return [String] what was done, one line
      # @raise [ConsoleCapture::Failure] naming `cannot pull main` and why
      def pull_main
        return "no origin/main to pull" unless fetched_origin_main?

        behind = count("main..#{REMOTE_MAIN}")
        return "main is up to date with #{REMOTE_MAIN}" if behind.zero?

        host = worktree_on("main")
        refuse_unready(host)
        ahead = count("#{REMOTE_MAIN}..main")
        return fast_forward(host, behind) if ahead.zero?

        rebase_main(host, ahead, behind)
      end

      # Fetches `origin` once; false when there is no origin or no `origin/main` to compare with.
      def fetched_origin_main?
        return false unless @git.capture("remote", "get-url", "origin", chdir: @checkout).ok?

        fetched = @git.capture("fetch", "--quiet", "origin", chdir: @checkout)
        raise ConsoleCapture::Failure, "cannot pull main: git fetch origin failed: #{fetched.err.strip}" unless fetched.ok?

        @git.capture("rev-parse", "--verify", "--quiet", "refs/remotes/#{REMOTE_MAIN}", chdir: @checkout).ok?
      end

      # Refuses a `main` checkout that is dirty or in the middle of a rebase or merge.
      def refuse_unready(host)
        return unless host

        midway = MIDWAY.find { |name, _| File.exist?(git_path(host.path, name)) }
        raise ConsoleCapture::Failure, "cannot pull main: the checkout is in the middle of a #{midway.last}" if midway

        changed = read("status", "--porcelain", "--untracked-files=no", dir: host.path)
        raise ConsoleCapture::Failure, "cannot pull main: the checkout has uncommitted changes" unless changed.empty?
      end

      def git_path(dir, name) = read("rev-parse", "--path-format=absolute", "--git-path", name, dir: dir)

      def fast_forward(host, behind)
        if host
          read("merge", "--ff-only", REMOTE_MAIN, dir: host.path)
        else
          read("fetch", "--quiet", "origin", "main:main")
        end
        "main fast-forwarded #{behind} commit#{"s" unless behind == 1} to #{short(read("rev-parse", "main"))}"
      end

      def rebase_main(host, ahead, behind)
        return pull_unhosted_main(ahead, behind) unless host

        note = carried_note
        result = @git.capture(*replay_identity(host.path), *rebase_args, chdir: host.path)
        refuse_conflict(host.path, ahead, result) unless result.ok?
        "main rebased #{ahead} unpushed commits onto #{REMOTE_MAIN} (#{behind} new) at #{short(read("rev-parse", "main"))}#{note}"
      end

      # Abandons a failed rebase in `dir` and refuses by name, leaving `main` where it was.
      def refuse_conflict(dir, ahead, result)
        raise ConsoleCapture::Failure,
              "cannot pull main: rebasing main's #{ahead} unpushed commits onto #{REMOTE_MAIN} " \
              "#{abandon_rebase(dir, result)}; nothing changed"
      end

      # Refuses landing a branch onto `main` while it lacks what `origin/main` has.
      def refuse_stale_base(branch)
        return unless fetched_origin_main?

        lacking = count("#{branch_tip(branch)}..#{REMOTE_MAIN}")
        return if lacking.zero? || ancestor?(branch_tip(branch), branch_tip("main"))

        raise ConsoleCapture::Failure, "#{branch} lacks #{lacking} commit#{"s" unless lacking == 1} that origin/main has: " \
                                       "pull main first (LinkedTree.pull_main!) and rebase the branch onto it"
      end
    end
  end
end
