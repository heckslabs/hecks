# frozen_string_literal: true

require_relative "price_table"
require_relative "trigger_kinds"

module Hecks
  module Adapters
    class Metering
      # What the turns of some usage rows cost to re-read: how many there were, the context each
      # read in (input, cache write and cache read) and what set each going, by {TriggerKinds}
      # label.
      module TurnCounts
        module_function

        # @param row [Hash] a usage row
        # @return [Integer] the tokens the turn read in
        def context(row)
          row.fetch(:context) { row[:input] + row[:cache_creation] + row[:cache_read] }
        end

        # @param rows [Array<Hash>] usage rows, one per turn
        # @return [Hash] `turns`, `context` (their sum), `mean_context` and `max_context`
        def of(rows)
          reads = rows.map { |row| context(row) }
          { turns: rows.size, context: reads.sum, mean_context: reads.empty? ? 0 : reads.sum / reads.size,
            max_context: reads.max || 0 }
        end

        # @param rows [Array<Hash>] usage rows, one per turn
        # @return [Array<Hash>] a line per trigger label: `trigger`, its turns, context and dollars
        def by_trigger(rows)
          groups = rows.group_by { |row| row[:trigger] || TriggerKinds::OTHER }
          groups.map { |label, turns| line(label, turns) }.sort_by { |line| -line[:context] }
        end

        def line(label, turns)
          { "trigger" => label, **of(turns), dollars: turns.sum { |row| PriceTable.dollars(row[:model], row) }.round(4) }
        end
      end
    end
  end
end
