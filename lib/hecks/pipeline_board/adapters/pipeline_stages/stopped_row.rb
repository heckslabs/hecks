# frozen_string_literal: true

require_relative "../rules"

module Hecks
  module Adapters
    module PipelineBoard
      # The strip's row for the open findings stopped integration runs and shipments filed: how
      # many are open, and for each its run, the stage it stopped at and the first line of the
      # reason. A log of stops, not a count of runs stopped now. Nothing while none is open or the
      # read failed, as the red flag row.
      module StoppedRow
        NAME = "Stopped runs"

        module_function

        # @param runs [Array<Hash>, Hash, nil] the `stopped_runs` section: each finding's `finding`,
        #   `stage`, `commit` and `body`, or `{unknown:}` when it could not be read
        # @return [Array<Hash>] one row with `name`, `state`, `count` and `detail`, or none
        def build(runs)
          return [] unless runs.is_a?(Array) && runs.any?

          [{ name: NAME, state: Rules.verdict(NAME, {}), count: runs.size.to_s,
             detail: runs.map { |run| line(run) }.join("; ") }]
        end

        # @param run [Hash] one stopped-run finding
        # @return [String] its run, stage and the first line of its reason
        def line(run)
          "#{run[:finding].to_s[0, 10]} at #{run[:stage]}: #{first_line(run[:body].to_s)}"
        end

        # @param reason [String] a stop's reason
        # @return [String] its first line, trimmed
        def first_line(reason)
          line = reason.lines.first
          line.to_s.strip
        end
      end
    end
  end
end
