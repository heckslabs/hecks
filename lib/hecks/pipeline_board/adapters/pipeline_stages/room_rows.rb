# frozen_string_literal: true

require_relative "../rules"

module Hecks
  module Adapters
    module PipelineBoard
      # The strip's two rows that say whether the pipeline has room to start work: Signalbox's
      # signal, as the board's load guard read it, and the last fill, explained. Each state is
      # the `Signal` or `Fill` rows' verdict; a row whose reading is absent is unread, never ok.
      module RoomRows
        NO_SIGNAL = "unknown: Signalbox's signal does not drive here"

        module_function

        # @param read [Hash, nil] the load guard's reading of the signal: `band`, `short` and
        #   `said`; nil while the signal does not drive or no guard stands
        # @return [Hash] the Signal row
        def signal(read)
          return row("Signal", { short: nil }, "-", NO_SIGNAL) unless read

          row("Signal", { short: read[:short] ? 1 : 0 }, read[:band], read[:said].to_s)
        end

        # @param fill [Hash] the last fill's report, or `{unknown: reason}`
        # @return [Hash] the Fill row: seats started of the cap, and what would start or was skipped
        def fill(fill)
          unread = fill.is_a?(Hash) ? fill[:unknown] : "no data"
          return row("Fill", { headroom: nil }, "-", "unknown: #{unread}") if unread

          row("Fill", { headroom: fill[:headroom] }, "#{fill[:started]} of #{fill[:cap]}", explained(fill))
        end

        # @return [String] how many would start and how many were skipped, the reasons counted
        def explained(fill)
          skipped = Array(fill[:skipped])
          reasons = skipped.map { |held| held[:reason].to_s }.tally.map { |reason, count| "#{count} #{reason}" }
          ["would start #{Array(fill[:would_start]).size}, skipped #{skipped.size}", *reasons].join("; ")
        end

        # @return [Hash] one row of the strip, its state by the `Verdict` rows of its name
        def row(name, measures, count, detail)
          { name: name, state: Rules.verdict(name, measures), count: count.to_s, detail: detail }
        end
      end
    end
  end
end
