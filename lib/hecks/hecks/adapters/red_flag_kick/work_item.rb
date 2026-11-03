# frozen_string_literal: true

module Hecks
  module Adapters
    class RedFlagKick
      # The red-* Work item a kick files for the batch it undid, and the outcome its coder is
      # briefed on: the flag, the failing CI run and its failed jobs, and the commits undone,
      # newest first.
      class WorkItem
        # @param flag [Hash] the flag the kick acts on
        # @param batch [Array<String>] the commits undone, newest first
        # @param branch [String] the branch the restore is on
        def initialize(flag, batch, branch)
          @flag = flag
          @batch = batch
          @branch = branch
        end

        # @return [String] the work item's key, `red-` and the flag's id
        def key = "#{WORK_PREFIX}#{@flag["id"]}"

        # @return [String] the work item's title, which is the outcome the coder is briefed on
        def title = "Bring main back green: the push batch rolled back for #{@flag["id"]} lands again once fixed"

        # @return [String] the flag's commit, CI run and failed jobs, and the commits undone
        def detail
          run = Array(@flag["runs"]).first || {}
          "Main was red at #{@flag["commit"]} (#{@flag["id"]}), CI run #{run["ci_run"]}; failed jobs: " \
            "#{Array(run["jobs"]).join(", ")}. #{@branch} restored main to its last green tree, undoing these " \
            "commits, newest first: #{@batch.join(", ")}. " \
            "Fix the failure on a branch that reapplies them and land it; the restore stays on main."
        end
      end
    end
  end
end
