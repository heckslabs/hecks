# frozen_string_literal: true

module Hecks
  module Adapters
    class Dispatching
      # The work items that hold a seat under the cap: the started ones, and each planned one whose
      # run is still started with a session behind it. A start refused after its launch leaves the
      # work item planned beside a live run; the run still takes the seat until it ends.
      module LiveRuns
        module_function

        # @param started [Array<Plan::Item>] the started work items
        # @param planned [Array<Plan::Item>] the planned work items
        # @param runs [Hash{String => Hash}] the AgentRun states by run key
        # @return [Array<Plan::Item>] the started items and the planned ones with a live run
        def holders(started, planned, runs)
          kept = started.map(&:key)
          started + planned.select { |item| live?(runs[item.key]) && !kept.include?(item.key) }.uniq(&:key)
        end

        # @param run [Hash, nil] one run's state
        # @return [Boolean] whether the run is started and its session is recorded
        def live?(run) = run.to_h[:status].to_s == "started" && !run.to_h[:session].to_s.empty?
      end
    end
  end
end
