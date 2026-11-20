# frozen_string_literal: true

require "hecks/hecks/adapters/console_capture"
require_relative "bound_holds"

module Hecks
  module Adapters
    class GitLanding
      # What refuses a landing before it takes a place in the line: unsaved work, the target as the
      # branch, and whatever the project's `Holds` port says holds a landing onto main, in its own
      # words. The including class answers `common_git_dir`, `worktree_on`, `dirty`,
      # `unsaved_refusal` and `@registry`.
      module Held
        private

        # Refuses a landing from a worktree that holds uncommitted work, naming the files.
        def refuse_unsaved(branch)
          tree = worktree_on(branch)
          changed = tree ? dirty(tree.path) : []
          raise ConsoleCapture::Failure, unsaved_refusal(tree.path, changed) unless changed.empty?
        end

        # Refuses a branch that is the target itself, then one that the project holds back.
        def refuse_landing(branch, onto)
          raise ConsoleCapture::Failure, "#{branch} is the branch to land onto" if branch == onto

          refuse_held(branch, onto)
        end

        # @param branch [String] the branch about to land
        # @param onto [String] the branch it lands on
        # @return [void]
        # @raise [ConsoleCapture::Failure] when the adapter bound to `Holds` holds the landing
        def refuse_held(branch, onto)
          return unless onto == "main"

          BoundHolds.new(@registry).hold(branch, onto, common_git_dir)
        end
      end
    end
  end
end
