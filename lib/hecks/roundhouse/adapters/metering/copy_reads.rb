# frozen_string_literal: true

require "hecks/hecks/adapters/shell"

module Hecks
  module Adapters
    class Metering
      # The copies part of the meter (ADR 0222, phase 3, reaping): each worktree of the checkout
      # under `.claude/worktrees`, its branch, whether that branch is on `main`, the files it holds
      # that are not committed and not ignored, and the minutes since it was cut. It reads with
      # `git` and changes nothing.
      class CopyReads
        # Where the pipeline's worktrees stand inside the checkout.
        WORKTREES = "/.claude/worktrees/"

        # @param root [String] any directory of the checkout
        # @param now [#call] answers the time
        # @param shell [Shell] runs `git`
        def initialize(root, now: -> { Time.now }, shell: Shell.new)
          @root = root
          @now = now
          @shell = shell
        end

        # @return [Array<Hash>] one row for each copy: `path`, `branch`, `landed` (yes or no),
        #   `unsaved` and `idle_minutes`
        def call
          listed.select { |path, branch| path.include?(WORKTREES) && !branch.empty? }
                .map { |path, branch| row(path, branch) }
        rescue SystemCallError
          []
        end

        private

        def row(path, branch)
          { path: path, branch: branch, landed: landed?(branch) ? "yes" : "no", unsaved: unsaved(path),
            idle_minutes: idle(path) }
        end

        # @return [Array<Array(String, String)>] each worktree's path and branch, from the porcelain
        def listed
          blocks = git("-C", @root, "worktree", "list", "--porcelain").out.split("\n\n")
          blocks.map do |block|
            lines = block.lines.map(&:strip)
            [field(lines, "worktree "), field(lines, "branch refs/heads/")]
          end
        end

        def field(lines, mark) = lines.find { |line| line.start_with?(mark) }.to_s.delete_prefix(mark)

        def landed?(branch) = git("-C", @root, "merge-base", "--is-ancestor", branch, "main").ok?

        # An unreadable tree counts as one unsaved file, so it is never reaped.
        def unsaved(path)
          result = git("-C", path, "status", "--porcelain")
          result.ok? ? result.out.lines.count { |line| !line.strip.empty? } : 1
        end

        def idle(path)
          cut = File.join(path, ".git")
          File.exist?(cut) ? ((@now.call - File.mtime(cut)) / SECONDS_PER_MINUTE).floor : 0
        end

        def git(*) = @shell.capture("git", *)
      end
    end
  end
end
