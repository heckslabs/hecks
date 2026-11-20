# frozen_string_literal: true

module Hecks
  module Adapters
    class Metering
      # How the meter finds a listed session's run: the AgentRun ledger records a session under the
      # short id `claude agents --json` lists as `id`, and a run recorded under the full `sessionId`
      # is still found by it.
      module SessionRuns
        module_function

        # @param runs [Hash{String => Hash}] each session's run, as {LiveReads#runs} answers
        # @param entry [Hash] the session as `claude agents --json` lists it
        # @return [Hash, nil] its run, by the listed `id`, else by its `sessionId`; nil when unrun
        def of(runs, entry)
          runs.values_at(entry["id"].to_s, entry["sessionId"].to_s).compact.first
        end
      end
    end
  end
end
