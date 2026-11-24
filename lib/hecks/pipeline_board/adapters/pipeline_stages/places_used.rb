# frozen_string_literal: true

require "hecks/hecks/adapters/dispatching/stop_reason"
require "hecks/hecks/adapters/dispatching/stall_reading"

module Hecks
  module Adapters
    module PipelineBoard
      # The `PlacesUsed` row: the places the last fill had used of its cap, and its skipped Work
      # items counted by the kind that held each. The kind is the dispatch's own, from
      # `Dispatching::StallReading` and `StopReason`; this module only counts them.
      module PlacesUsed
        module_function

        # @param fill [Hash] the fill report as read, or `{unknown: reason}`
        # @return [Hash] `used`, `cap`, `free`, `skips` (`kind` and `count`) and `note`
        def of(fill)
          return row(0, 0, [], "unknown: #{fill[:unknown]}") if fill.key?(:unknown)

          cap = fill[:cap].to_i
          used = fill[:headroom] ? cap - fill[:headroom] : fill[:started].to_i
          row(used, cap, skips(Array(fill[:skipped])), "")
        end

        def row(used, cap, skips, note)
          { used: used, cap: cap, free: [cap - used, 0].max, skips: skips, note: note }
        end

        # @return [Array<Hash>] a `SkipCount` for each kind among the skipped items
        def skips(skipped)
          skipped.map { |held| kind_of(held[:reason].to_s) }.tally.map { |kind, count| { kind: kind, count: count } }
        end

        def kind_of(reason)
          Dispatching::StallReading::KINDS.find { |pattern, _| pattern.match?(reason) }&.last ||
            Dispatching::StopReason.kind_of(reason)
        end
      end
    end
  end
end
