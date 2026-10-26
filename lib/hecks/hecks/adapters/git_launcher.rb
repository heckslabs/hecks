# frozen_string_literal: true

require_relative "console_capture"
require_relative "git"

module Hecks
  module Adapters
    # The `Launcher` port's adapter: keeps the copy of Hecks that runs the push train on the branch
    # it just pushed, so the next boarding (and the records it keeps) runs the code that landed.
    #
    # It moves only a copy that is a detached, clean checkout of the same repository the push went
    # to; any other copy (an installed gem, a checkout on a branch, one with edits, another
    # repository) is left as it is and the answer says why. Moving it is a fetch and a detached
    # checkout of the pushed commit, never a reset of a branch.
    class GitLauncher
      # The directory this copy of Hecks runs from.
      ROOT = File.expand_path("../../../..", __dir__)

      # Accepts the arguments every driven adapter is built with; `root` names the copy to keep
      # current, for a test, and defaults to the running one.
      #
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] unused
      # @param root [String, nil] the copy of Hecks to move
      def initialize(aggregate: nil, settings: {}, root: nil)
        @git = Git.new
        @root = root || ROOT
      end

      # Moves the running copy of Hecks to the commit a boarding pushed, when it is a detached,
      # clean checkout of the same repository.
      #
      # @param held [Hash] the `PushTrain` record: `checkout`, `remote` and `pushed`
      # @return [Hash{Symbol => Hash}] `report:` where the copy now stands, or why it was left
      # @raise [ConsoleCapture::Failure] when the copy should move and git refuses
      def refresh(**held)
        reason = left_as_is(held)
        return { report: { value: "launcher left at #{head}: #{reason}" } } if reason

        before = head
        move_to(plain(held[:remote]), plain(held[:pushed]))
        { report: { value: "launcher #{before} -> #{head}" } }
      end

      private

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

      def move_to(remote, commit)
        [["fetch", "-q", remote], ["checkout", "-q", "--detach", commit]].each do |args|
          done = git(*args)
          raise ConsoleCapture::Failure, "git #{args.first} in #{@root}: #{done.err.strip}" unless done.ok?
        end
      end

      def head = git("rev-parse", "--short", "HEAD").out.strip

      def git(*) = @git.capture(*, chdir: @root)

      def plain(argument) = argument.is_a?(Hash) ? argument[:value] : argument
    end
  end
end
