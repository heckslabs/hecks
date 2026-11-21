# frozen_string_literal: true

module Hecks
  module Adapters
    class Sweeping
      class Worktrees
        # The worktrees of one repository as `git worktree list --porcelain` prints them, the
        # primary checkout left out.
        class Listing
          Entry = Struct.new(:path, :tip, :branch)
          BLANK_LINES = /\n\n+/

          # @param shell [Shell] runs `git`
          # @param repo [String] any checkout of the repository
          def initialize(shell:, repo:)
            @shell = shell
            @repo = repo
          end

          # @return [Array<Entry>] each linked worktree; empty when git cannot list them
          def linked
            result = @shell.capture("git", "-C", @repo, "worktree", "list", "--porcelain")
            return [] unless result.ok?

            blocks(result.out).filter_map { |block| entry(block) }
          end

          private

          # The primary checkout is the first block; it is left out.
          def blocks(text) = text.split(BLANK_LINES).drop(1)

          def entry(block)
            fields = block.lines.to_h { |line| line.strip.split(" ", 2).then { |key, value| [key, value] } }
            return nil unless fields["worktree"]

            Entry.new(fields["worktree"], fields["HEAD"], fields["branch"]&.delete_prefix("refs/heads/"))
          end
        end
      end
    end
  end
end
