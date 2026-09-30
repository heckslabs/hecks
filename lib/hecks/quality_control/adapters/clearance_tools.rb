# frozen_string_literal: true

require_relative "qa_tool"

module Hecks
  module Adapters
    # The `ClearanceTools` port's adapter: answers `Clearance`'s query by running the PR check. A
    # newly red PR ends the check with status 2, which is an answer; anything else it calls an
    # error is refused with its report.
    class ClearanceTools < QaTool
      # @return [String] what the check found for each open PR the ledger tracks
      def check_pull_requests
        run_command("qa_pr_check", answers: [0, 2])
      end
    end
  end
end
