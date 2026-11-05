# frozen_string_literal: true

require_relative "../git_strays"

module Hecks
  module Adapters
    class GitLanding
      # Moving a stray out of the checkout that a landing would refuse for. The including class
      # answers `settle`, `plain` and `@git`.
      module Sheltering
        # Moves an untracked path, or a clean linked worktree whose commits are all on `main` or a
        # remote, out of the checkout into a holding directory. It never deletes anything.
        #
        # @param held [Hash] the `Landing` record: `checkout`, `path` (relative to the checkout) and
        #   `holding` (the job's `tmp` directory, else `~/.claude/set-aside`, when absent)
        # @return [Hash{Symbol => Hash}] `report:` where it went and the command that puts it back
        # @raise [ConsoleCapture::Failure] when the path is tracked, holds unsaved work, or is
        #   outside the checkout
        def move_aside(**held)
          settle(held)
          shelf = GitStrays::Shelf.new(@git, @checkout)
          { report: { value: shelf.move(plain(held[:path]), holding: plain(held[:holding])) } }
        end
      end
    end
  end
end
