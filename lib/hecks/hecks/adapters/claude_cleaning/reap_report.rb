# frozen_string_literal: true

module Hecks
  module Adapters
    class ClaudeCleaning
      # The one line a reap reports:
      # `removed N sessions and M worktrees; kept K: <name> (<reason>)`.
      #
      # It counts the runs `AgentRun.Tidy` took away since the reap began (the ledger's `tidied`
      # rows stamped at or after it), the worktrees among them (a retired worktree leaves
      # `worktree retired` in the run's detail), the sessions {PlainSweep} removed, and names each
      # finished run still kept with the reason its `Retain` recorded.
      class ReapReport
        # What `AgentRun.Detach` writes into a run's detail.
        RETIRED = "worktree retired"

        # @param runs [Array<Hash>] each run's `:run`, `:session`, `:status`, `:tidied_at`,
        #   `:detail` and `:refusal`
        def initialize(runs)
          @runs = runs
        end

        # @param since [String] when the reap began, ISO 8601
        # @param plain [PlainSweep::Result] what the sweep of the sessions no run holds did
        # @return [String] the report line
        def line(since, plain)
          gone = @runs.select { |run| run[:status] == "tidied" && run[:tidied_at].to_s >= since.to_s }
          kept = kept_runs + plain.kept
          removed = gone.length + plain.removed.length
          "removed #{removed} sessions and #{retired(gone)} worktrees; kept #{kept.length}#{named(kept)}"
        end

        private

        def retired(gone) = gone.count { |run| run[:detail].to_s.start_with?(RETIRED) }

        def kept_runs
          @runs.select { |run| run[:status] == "finished" && !run[:refusal].to_s.empty? }
               .map { |run| [run[:run], run[:refusal]] }
        end

        def named(kept) = kept.empty? ? "" : ": #{kept.map { |name, why| "#{name} (#{why})" }.join(", ")}"
      end
    end
  end
end
