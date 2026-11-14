# frozen_string_literal: true

require "hecks/hecks/adapters/git_worktrees"

module Hecks
  module Adapters
    # What a checkout still holds that no branch names: its stash entries, and the commits no ref
    # reaches (what `git fsck --unreachable --no-reflogs` reports as commits). It only reads: no
    # stash is applied, popped, dropped or branched, and nothing is pruned, collected or repaired.
    #
    # An includer of `GitRecovery` is constructed with `@git` (the `Git` adapter) and the
    # repository's top level, and reads through `GitTrain::Reading`.
    class GitRecovery
      include GitTrain::Reading

      # The branch a stash message records: `WIP on <branch>: ...` or `On <branch>: ...`.
      BRANCH_OF_MESSAGE = /\A(?:WIP on|On) ([^:]+):/

      # One `git stash list` line: the ref, the commit time and the reflog message, tab-separated.
      STASH_FORMAT = "%gd%x09%cI%x09%gs"

      # One `git show` line for an unreachable commit: the sha, the author date and the subject.
      COMMIT_FORMAT = "%H%x09%aI%x09%s"

      # @param git [Git] the adapter every git call goes through
      # @param checkout [String] the repository's top level
      def initialize(git, checkout)
        @git = git
        @checkout = checkout
      end

      # @return [String] one tab-separated line per entry: the ref, the time, the branch the stash
      #   records (or `no branch recorded`) and the message; `no stashes` when there are none
      def stashes
        lines = read("stash", "list", "--format=#{STASH_FORMAT}").lines.map(&:chomp).reject(&:empty?)
        lines.empty? ? "no stashes" : lines.map { |line| stash_line(line) }.join("\n")
      end

      # @return [String] one tab-separated line per unreachable commit, newest author date first:
      #   the short sha, the author date, and the subject; `no dangling commits` when there are none
      def dangling_commits
        shas = unreachable_commits
        return "no dangling commits" if shas.empty?

        newest_first(shas.map { |sha| commit_line(sha) }).join("\n")
      end

      private

      def stash_line(line)
        ref, time, message = line.split("\t", 3)
        branch = message.to_s[BRANCH_OF_MESSAGE, 1] || "no branch recorded"
        [ref, time, branch, message].join("\t")
      end

      # The commits `fsck` lists as unreachable; blobs and trees are not commits and are left out.
      def unreachable_commits
        read("fsck", "--unreachable", "--no-reflogs").lines.filter_map do |line|
          line.split[2] if line.start_with?("unreachable commit ")
        end
      end

      # Sorts commit lines by their author date, the second field, newest first.
      def newest_first(lines) = lines.sort_by { |line| line.split("\t")[1] }.reverse

      def commit_line(sha)
        short, date, subject = read("show", "-s", "--format=#{COMMIT_FORMAT}", sha).split("\t", 3)
        [short[0, 9], date, subject].join("\t")
      end
    end
  end
end
