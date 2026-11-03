# frozen_string_literal: true

module Hecks
  module Adapters
    class RedFlagKick
      # The red-* Work row a kick files for the batch it reverted, and the outcome its coder is
      # briefed on: the flag, the failing CI run and its failed jobs, and the commits reverted,
      # newest first.
      class WorkRow
        # @param flag [Hash] the flag the kick acts on
        # @param batch [Array<String>] the commits reverted, newest first
        # @param branch [String] the branch the revert is on
        def initialize(flag, batch, branch)
          @flag = flag
          @batch = batch
          @branch = branch
        end

        # @return [String] the row's key, `red-` and the flag's id
        def key = "#{ROW}#{@flag["id"]}"

        # @return [String] the row's title, which is the outcome the coder is briefed on
        def title = "Bring main back green: the push batch kicked off main for #{@flag["id"]} lands again once fixed"

        # @return [String] the flag's commit, CI run and failed jobs, and the commits reverted
        def detail
          run = Array(@flag["runs"]).first || {}
          "Main was red at #{@flag["commit"]} (#{@flag["id"]}), CI run #{run["ci_run"]}; failed jobs: " \
            "#{Array(run["jobs"]).join(", ")}. #{@branch} reverted these commits, newest first: #{@batch.join(", ")}. " \
            "Fix the failure on a branch that reapplies them and land it; the revert stays on main."
        end
      end
    end
  end
end
