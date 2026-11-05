# frozen_string_literal: true

require "time"

module Hecks
  module Adapters
    module PipelineBoard
      # What every tile builder shares: the tile's shape, its trend against the earlier half of a
      # window, and the small statistics.
      module TileKit
        # @return [Hash] a tile with its number, unit, state word, trend and detail line
        def tile(id, label, value, unit, extra = {})
          state = value.nil? ? "unknown" : "ok"
          { id: id, label: label, value: value, unit: unit, state: state, detail: "", trend: nil }.merge(extra)
        end

        # @return [Hash] a tile for a section that could not be read, saying why
        def unknown_tile(id, label, section)
          reason = section.is_a?(Hash) ? section[:unknown] : "nothing to read"
          tile(id, label, nil, "", detail: "unknown: #{reason}")
        end

        # @return [Hash] the change between two numbers; `better` is true when it improved
        def trend(before, after, unit, lower_is_better: false)
          return nil if before.nil? || after.nil?

          delta = (after - before).round(1)
          { delta: delta, unit: unit, better: delta.zero? ? nil : (delta.negative? == lower_is_better) }
        end

        # @return [Array<Array>] the earlier and the later half of a list
        def halves(list)
          cut = list.size / 2
          [list.first(cut), list.drop(cut)]
        end

        # @return [Float, nil] the middle of the numbers, nil when there are none
        def median(list)
          sorted = list.compact.sort
          return nil if sorted.empty?

          ((sorted[(sorted.size - 1) / 2] + sorted[sorted.size / 2]) / 2.0).round(1)
        end

        # @return [Integer, nil] the share of runs that succeeded, as a whole percent
        def success_rate(list)
          return nil if list.empty?

          (100.0 * list.count { |run| Hecks::CheckConclusion.certifies?(run[:conclusion]) } / list.size).round
        end

        # @return [Time] when a run ended: its start plus its wall time
        def finished(run) = Time.parse(run[:started]) + (run[:wall_minutes].to_f * 60)
      end
    end
  end
end
