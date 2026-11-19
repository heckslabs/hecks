# frozen_string_literal: true

require_relative "console_capture"
require_relative "git"
require_relative "main_integration/kept_rows"
require_relative "main_integration/local_world"

module Hecks
  module Adapters
    # The `Launcher` port's adapter: keeps the push train's copy (`~/.claude/hecks-train`) on the
    # commit a boarding pushed or a train pull request merged, whichever process recorded it, so
    # the clock's beats and the next boarding run the code that landed, with the owner's local
    # files linked in (see {MainIntegration::LocalWorld}).
    #
    # It moves only a copy that is a detached, clean checkout of the same repository the push went
    # to, and never backwards: a copy that already holds the pushed commit stays. Any other copy is
    # left as it is and the answer says why. Moving it is a fetch and a detached checkout of the
    # pushed commit, never a reset of a branch. Under the spec runner no live copy is named, so a
    # spec moves only the copy it gives.
    class GitLauncher
      # The switch the spec runner sets; with it, no root given means no copy to move.
      SPEC_SWITCH = "HECKS_WRITES_LOCAL"

      # Accepts the arguments every driven adapter is built with; `root` names the copy to keep
      # current, for a test, and defaults to the push train's copy.
      #
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] unused
      # @param root [String, nil] the copy of Hecks to move
      # @param env [#[]] where the spec runner's switch is read
      def initialize(aggregate: nil, settings: {}, root: nil, env: ENV)
        @git = Git.new
        @root = root || (MainIntegration::KeptRows::TRAIN_ROOT unless env[SPEC_SWITCH])
      end

      # Moves the train's copy to the commit a boarding pushed, when it is a detached, clean
      # checkout of the same repository that does not hold the commit yet, and links the local
      # files of the checkout that boarded.
      #
      # @param held [Hash] the `PushTrain` record: `checkout`, `remote` and `pushed`
      # @return [Hash{Symbol => Hash}] `report:` where the copy now stands, or why it was left
      # @raise [ConsoleCapture::Failure] when the copy should move and git refuses
      def refresh(**held)
        return report("launcher left: the spec runner names no train copy") unless @root

        reason = left_as_is(held)
        return report("launcher left at #{head}: #{reason}") if reason

        report("#{advance(plain(held[:remote]), plain(held[:pushed]))}; #{link(plain(held[:checkout]))}")
      end

      private

      def report(text) = { report: { value: text } }

      def advance(remote, commit)
        before = head
        run!("fetch", "-q", remote)
        return "launcher at #{before} already holds #{commit.to_s[0, 9]}" if holds?(commit)

        run!("checkout", "-q", "--detach", commit)
        "launcher #{before} -> #{head}"
      end

      def holds?(commit) = git("merge-base", "--is-ancestor", commit, "HEAD").ok?

      # The boarding checkout's local files, from its main checkout when it is a linked worktree.
      def link(checkout)
        worktree = WorktreeOverlay.checkout_root(checkout)
        owner = (worktree && WorktreeOverlay.main_checkout(worktree)) || checkout
        MainIntegration::LocalWorld.new(@root, owner).sync
      end

      def left_as_is(held)
        return "not a git checkout" unless git("rev-parse", "--git-dir").ok?
        return "on a branch, not detached" if git("symbolic-ref", "-q", "HEAD").ok?
        return "has local edits (#{first_edit})" if first_edit
        return "a checkout of another repository" unless same_repository?(held)

        nil
      end

      # The first changed or untracked path, as `git status --porcelain` writes it, so the report
      # says which file keeps the copy from moving.
      def first_edit = status_lines.first&.strip

      def status_lines = git("status", "--porcelain").out.lines

      def same_repository?(held)
        pushed_to = @git.capture("remote", "get-url", plain(held[:remote]), chdir: plain(held[:checkout]))
        mine = git("remote", "get-url", plain(held[:remote]))
        pushed_to.ok? && mine.ok? && pushed_to.out.strip == mine.out.strip
      end

      def run!(*args)
        done = git(*args)
        raise ConsoleCapture::Failure, "git #{args.first} in #{@root}: #{done.err.strip}" unless done.ok?
      end

      def head = git("rev-parse", "--short", "HEAD").out.strip

      def git(*) = @git.capture(*, chdir: @root)

      def plain(argument) = argument.is_a?(Hash) ? argument[:value] : argument
    end
  end
end
