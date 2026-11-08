# frozen_string_literal: true

require_relative "../red_flag_guard"
require_relative "../boarding_hold_marker"
require_relative "../console_capture"
require_relative "../../../indifferent_key"

module Hecks
  module Adapters
    class GitLanding
      # What refuses a landing before it takes a place in the line: unsaved work, the target as the
      # branch, and a boarding hold on main, by name, until the hold is released or its window ends.
      # The fix of a red Work item is exempt from the hold, as under a red flag. The including class
      # answers `common_git_dir`, `worktree_on`, `dirty`, `unsaved_refusal` and `@registry`.
      module Held
        private

        # Refuses a landing from a worktree that holds uncommitted work, naming the files.
        def refuse_unsaved(branch)
          tree = worktree_on(branch)
          changed = tree ? dirty(tree.path) : []
          raise ConsoleCapture::Failure, unsaved_refusal(tree.path, changed) unless changed.empty?
        end

        # Refuses a branch that is the target itself, then one that a boarding hold keeps out.
        def refuse_landing(branch, onto)
          raise ConsoleCapture::Failure, "#{branch} is the branch to land onto" if branch == onto

          refuse_held(branch, onto)
        end

        # @param branch [String] the branch about to land
        # @param onto [String] the branch it lands on
        # @return [void]
        # @raise [ConsoleCapture::Failure] when main is held for a boarding and the branch is not a
        #   red Work item's fix
        def refuse_held(branch, onto)
          return unless onto == "main"
          return if RedFlagGuard.fix?(branch)

          marker = BoardingHoldMarker.new(common_git_dir, minutes: hold_window)
          hold = marker.active
          raise ConsoleCapture::Failure, marker.refusal(hold) if hold
        end

        # The minutes a hold lasts: the world's `boarding_hold` setting, else the default.
        def hold_window
          setting = (@registry&.world("Hecks")&.settings || {})["boarding_hold"]
          (setting && IndifferentKey.read(setting, :max_minutes)) || BoardingHoldMarker::DEFAULT_MINUTES
        end
      end
    end
  end
end
