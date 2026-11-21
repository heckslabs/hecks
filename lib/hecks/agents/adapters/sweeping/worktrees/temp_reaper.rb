# frozen_string_literal: true

require "hecks/hecks/adapters/shell"

module Hecks
  module Adapters
    class Sweeping
      class Worktrees
        # Acts on the `temp` lines {Worktrees} names: a branchless, clean, absorbed, idle worktree
        # under a temp root. No `hecks` command removes a worktree without a branch
        # (`Landing.retire!` needs one), so it runs plain `git worktree remove`, never forced; a
        # refusal (untracked files, a lock) is a reported line, not an error.
        class TempReaper
          # @param shell [Shell] runs `git`
          # @param repo [String] any checkout of the repository
          def initialize(shell:, repo:)
            @shell = shell
            @repo = repo
          end

          # @param lines [Array<String>] the worktree lines
          # @param remove [Boolean] false only says what would be removed
          # @return [Array<String>] the lines, each `temp` one replaced by what became of it
          def apply(lines, remove:)
            lines.map { |line| line.start_with?("temp  ") ? outcome(line.split("  ")[1], remove) : line }
          end

          private

          def outcome(path, remove)
            return "would remove  #{path}" unless remove

            result = @shell.capture("git", "-C", @repo, "worktree", "remove", path)
            result.ok? ? "removed  #{path}" : "kept  #{path}  #{result.err.strip}"
          end
        end
      end
    end
  end
end
