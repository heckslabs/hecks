# frozen_string_literal: true

require_relative "git"
require_relative "git_worktrees"

module Hecks
  module Adapters
    # The `Publishing` port's adapter for `LinkedTree`: pushes a worktree's branch to `origin`
    # under its own name, so a pull request can be opened from it.
    #
    # It never pushes `main`, never forces (no `--force` or `--force-with-lease`), and refuses a
    # branch with no commits to publish: the commits the remote branch lacks, or, for a branch the
    # remote does not have yet, the commits beyond `origin/main`. The remote-tracking refs are read
    # as they stand; nothing is fetched first, so a stale ref can only make the remote refuse.
    class GitPublish
      include GitWorktrees

      REMOTE = "origin"

      # Accepts the arguments every driven adapter is built with, and a `git` runner a spec may
      # stand in for. The default runs `git` for real.
      #
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] unused
      # @param root [String, nil] unused
      # @param git [#capture] the runner `Git` is, a stand-in in a spec
      def initialize(aggregate: nil, settings: {}, root: nil, git: Git.new)
        @git = git
      end

      # Pushes the branch to `origin` under its own name, and reads the sha it now publishes.
      #
      # @param held [Hash] the `LinkedTree` record: `checkout` (a directory inside the
      #   repository; the current directory when absent) and `branch` (a branch other than main)
      # @return [Hash{Symbol => Hash}] `sha:` the commit published, `report:` the remote's answer
      # @raise [ConsoleCapture::Failure] on a branch named main, a branch with nothing to publish,
      #   or a push the remote refuses, with the remote's reason
      def push(**held)
        settle(held)
        branch = publishable(held)
        ahead = count(unpublished(branch))
        raise ConsoleCapture::Failure, "nothing to publish: #{branch} has no commits the remote lacks" if ahead.zero?

        said = send_branch(branch)
        sha = read("rev-parse", "--short", "refs/heads/#{ref(branch)}")
        noun = ahead == 1 ? "commit" : "commits"
        { sha: { value: sha }, report: { value: "published #{branch}, #{ahead} #{noun}: #{said}" } }
      end

      private

      # The branch a publish pushes: a name, and never main.
      def publishable(held)
        branch = plain(held[:branch]).to_s.strip
        raise ConsoleCapture::Failure, "a branch is published under its own name" if branch.empty?
        raise ConsoleCapture::Failure, "main is never published" if branch == "main"

        branch
      end

      # The range of commits the remote lacks: against the branch on `origin`, or against
      # `origin/main` when the remote has no such branch yet.
      def unpublished(branch)
        remote_tip = "refs/remotes/#{REMOTE}/#{ref(branch)}"
        found = @git.capture("rev-parse", "--verify", "--quiet", remote_tip, chdir: @checkout).ok?
        base = found ? remote_tip : "#{REMOTE}/main"
        "#{base}..refs/heads/#{ref(branch)}"
      end

      # Pushes the branch to `origin` as a branch of the same name. No force flag, and the refspec
      # names the branch on both sides, so it can only land on that branch.
      def send_branch(branch)
        refspec = "refs/heads/#{ref(branch)}:refs/heads/#{ref(branch)}"
        pushed = @git.capture("push", REMOTE, refspec, chdir: @checkout)
        raise ConsoleCapture::Failure, "cannot publish #{branch}: #{pushed.err.strip}" unless pushed.ok?

        [pushed.err, pushed.out].join.strip
      end
    end
  end
end
