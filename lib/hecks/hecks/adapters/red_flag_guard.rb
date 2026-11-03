# frozen_string_literal: true

require_relative "red_flag_marker"
require_relative "console_capture"

module Hecks
  module Adapters
    # What a standing red flag refuses. While the flag stands, nothing lands on main and nothing is
    # boarded on the push train except a fix for a red Work item: a branch named for a `red-*` Work
    # item
    # (with or without a `qa/` lead) lands and records its tip on the flag, and the train carries
    # only that tip. The refusal names the flag: `main is red: flag <id>`.
    class RedFlagGuard
      # The Work items that say main is red are keyed with this prefix.
      RED_WORK_ITEM = "red-"

      # A branch lead the QA loop adds to a Work item's name.
      QA_LEAD = "qa/"

      # @param git_dir [String] the repository's common git directory
      def initialize(git_dir)
        @marker = RedFlagMarker.new(git_dir)
      end

      # @param branch [String] the branch about to land on main
      # @return [void]
      # @raise [ConsoleCapture::Failure] when a flag stands and the branch is not a red Work item's
      #   fix
      def landing!(branch)
        flag = @marker.read
        return unless flag
        return if fix?(branch)

        raise ConsoleCapture::Failure, "#{refusal(flag)}; #{branch} is not a fix for a red-* Work item"
      end

      # Records that a red Work item's fix landed, so the train may carry main's new tip.
      #
      # @param branch [String] the fix's branch
      # @param tip [String] main's commit after the landing
      # @return [void]
      def landed(branch, tip)
        @marker.fixed!(tip: tip, branch: branch) if @marker.read && fix?(branch)
      end

      # @param boarded [String] the commit the train would push
      # @return [void]
      # @raise [ConsoleCapture::Failure] when a flag stands and the commit is not the fix's tip
      def boarding!(boarded)
        flag = @marker.read
        return unless flag
        return if flag["fix_tip"] && flag["fix_tip"] == boarded

        raise ConsoleCapture::Failure, "#{refusal(flag)}; only the tip of a red-* Work item's fix is boarded"
      end

      private

      def fix?(branch) = branch.to_s.delete_prefix(QA_LEAD).start_with?(RED_WORK_ITEM)

      def refusal(flag) = "main is red: flag #{flag["id"]}"
    end
  end
end
