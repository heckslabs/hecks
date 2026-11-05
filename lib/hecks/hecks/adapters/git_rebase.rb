# frozen_string_literal: true

require_relative "git"
require_relative "git_worktrees"
require_relative "git_main_pull"

module Hecks
  module Adapters
    # The `Rebasing` port's adapter for `LinkedTree`: replays the branch a worktree has checked out
    # onto a base, and settles conflicts only with the sides the caller named.
    #
    # It refuses a dirty checkout, one in the middle of a rebase or merge, and a branch checked out
    # in no worktree. It never forces and never discards a change. A conflict on a path nobody
    # named aborts the rebase, so the branch is left as it was, and the refusal lists every
    # conflicted path with its sides.
    #
    # `ours` is the base the branch is rebased onto and `theirs` is the branch's commit being
    # replayed (git's rebase sense). The answer is the sha the branch stands on, and the paths
    # settled along the way.
    class GitRebase
      include GitWorktrees

      SIDES = %w[ours theirs].freeze

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

      # Replays the branch onto the base (the `Replay` ask), settling each named conflicted path
      # with its side.
      #
      # @param held [Hash] the `LinkedTree` record: `checkout` (a directory inside the repository),
      #   `branch` (a branch other than main), `onto` (a ref, `origin/main` by default) and
      #   `resolve` (`path=side` pairs)
      # @return [Hash{Symbol => Hash}] `sha:` the commit the branch stands on, `report:` what was
      #   done
      # @raise [ConsoleCapture::Failure] on a refused request, a dirty checkout, or a conflict
      #   nobody settled
      def replay(**held)
        settle(held)
        branch = named_branch(held)
        onto = base_named(held, branch)
        host = hosting(branch)
        refuse_unready(host, branch)
        resolved = rebase_or_abort(host, branch, onto, sides_named(held))
        sha = read("rev-parse", "--short", "HEAD", dir: host.path)
        { sha: { value: sha }, report: { value: report(branch, onto, sha, resolved) } }
      end

      private

      # The branch a rebase moves: a name, and never main.
      def named_branch(held)
        branch = plain(held[:branch]).to_s.strip
        raise ConsoleCapture::Failure, "a branch is rebased under its own name" if branch.empty?
        raise ConsoleCapture::Failure, "main is never rebased" if branch == "main"

        ref(branch)
      end

      # The base: a ref that resolves to a commit, and never the branch itself.
      def base_named(held, branch)
        onto = ref(plain(held[:onto]).to_s.strip)
        raise ConsoleCapture::Failure, "a branch is never rebased onto itself" if onto.delete_prefix("refs/heads/") == branch

        found = @git.capture("rev-parse", "--verify", "--quiet", "#{onto}^{commit}", chdir: @checkout)
        raise ConsoleCapture::Failure, "#{onto} is not a commit" unless found.ok?

        onto
      end

      # The worktree the branch is checked out in: the only place it can be rebased.
      def hosting(branch)
        host = worktree_on(branch)
        raise ConsoleCapture::Failure, "cannot rebase #{branch}: it is checked out in no worktree" unless host

        host
      end

      # Refuses a checkout that is dirty, or in the middle of a rebase or merge.
      def refuse_unready(host, branch)
        midway = GitMainPull::MIDWAY.find { |name, _| File.exist?(git_path(host.path, name)) }
        if midway
          raise ConsoleCapture::Failure,
                "cannot rebase #{branch}: its checkout is in the middle of a #{midway.last}"
        end

        changed = read("status", "--porcelain", "--untracked-files=no", dir: host.path)
        raise ConsoleCapture::Failure, "cannot rebase #{branch}: the checkout has uncommitted changes" unless changed.empty?
      end

      def git_path(dir, name) = read("rev-parse", "--path-format=absolute", "--git-path", name, dir: dir)

      # The paths the caller named and the side each takes, from `path=side` pairs. Nothing named
      # is none.
      def sides_named(held)
        plain(held[:resolve]).to_s.split(",").to_h do |pair|
          path, side = pair.split("=", 2)
          raise ConsoleCapture::Failure, "resolve takes path=ours or path=theirs, not #{pair}" unless SIDES.include?(side)

          [path, side]
        end
      end

      # Runs the rebase and aborts it if anything fails, so a refused rebase leaves the branch as
      # it was.
      def rebase_or_abort(host, branch, onto, sides)
        run_rebase(host, branch, onto, sides)
      rescue ConsoleCapture::Failure
        @git.capture("rebase", "--abort", chdir: host.path)
        raise
      end

      # Rebases, then settles each conflict round: every conflicted path must be named, or the
      # rebase stops.
      # @return [Array<String>] the paths settled along the way
      def run_rebase(host, branch, onto, sides)
        result = @git.capture("rebase", onto, chdir: host.path)
        resolved = []
        until result.ok?
          conflicts = unmerged(host)
          stop(branch, onto, conflicts, result) unless settleable?(conflicts, sides)
          resolved.concat(take_sides(host, conflicts, sides))
          result = @git.capture("-c", "core.editor=true", "rebase", "--continue", chdir: host.path)
        end
        resolved
      end

      def unmerged(host) = read("diff", "--name-only", "--diff-filter=U", dir: host.path).split("\n")

      def settleable?(conflicts, sides) = conflicts.any? && conflicts.all? { |path| sides.key?(path) }

      # Takes the named side of each conflicted path and stages it.
      def take_sides(host, conflicts, sides)
        conflicts.each do |path|
          read("checkout", "--#{sides.fetch(path)}", "--", path, dir: host.path)
          read("add", "--", path, dir: host.path)
        end
        conflicts
      end

      # Stops with the reason: every conflicted path with its sides, or git's own words when none
      # conflicted.
      def stop(branch, onto, conflicts, result)
        reason = conflicts.empty? ? result.err.strip : "conflicts in #{sided(conflicts, branch, onto)}"
        raise ConsoleCapture::Failure, "cannot rebase #{branch} onto #{onto}: #{reason}; nothing changed"
      end

      def sided(conflicts, branch, onto)
        conflicts.map { |path| "#{path} (ours is #{onto}, theirs is #{branch})" }.join("; ")
      end

      def report(branch, onto, sha, resolved)
        took = resolved.empty? ? "" : "; settled #{resolved.uniq.join(", ")}"
        "rebased #{branch} onto #{onto} at #{sha}#{took}"
      end
    end
  end
end
