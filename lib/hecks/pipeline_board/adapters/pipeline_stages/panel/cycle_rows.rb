# frozen_string_literal: true

module Hecks
  module Adapters
    module PipelineBoard
      module Panel
        # The panel's Cycles box: each stage's median and percentile over the recent Work items,
        # then the newest items, each with its time so far and the stage it is still in.
        class CycleRows
          # @param reading [Hash] what `Cycles.build` answered, or `{unknown: reason}`
          # @param limit [Integer] how many items are listed
          def initialize(reading, limit)
            @reading = reading
            @limit = limit
          end

          # @return [Array<Array(String, String)>] the box's rows, `[text, tone]` each
          def rows
            return [["unknown: #{@reading.to_h[:unknown] || "no data"}", "unknown"]] unless readable?
            return [["no cycle recorded", "unknown"]] if @reading[:cycles].empty?

            @reading[:stats].map { |stat| stat_row(stat) } + @reading[:cycles].first(@limit).map { |cycle| item_row(cycle) }
          end

          # @param seconds [Integer, nil]
          # @return [String] `1h02m`, `13m09s` or `39s`; `-` when nothing was measured
          def self.span(seconds)
            return "-" if seconds.nil?
            return format("%<h>dh%<m>02dm", h: seconds / 3600, m: seconds % 3600 / 60) if seconds >= 3600
            return format("%<m>dm%<s>02ds", m: seconds / 60, s: seconds % 60) if seconds >= 60

            "#{seconds}s"
          end

          private

          def readable? = @reading.is_a?(Hash) && @reading[:stats].is_a?(Array)

          def stat_row(stat)
            cells = [stat[:stage].to_s.ljust(13), "median #{CycleRows.span(stat[:median])}".ljust(16),
                     "p#{@reading[:rank]} #{CycleRows.span(stat[:percentile])}".ljust(14), "over #{stat[:items]}"]
            [cells.join(" "), "ok"]
          end

          def item_row(cycle)
            where = cycle[:open] ? "in #{cycle[:open]}" : "through #{cycle[:stages].last[:stage]}"
            ["#{cycle[:work]}  #{CycleRows.span(cycle[:seconds])}  #{where}", cycle[:open] ? "working" : "ok"]
          end
        end
      end
    end
  end
end
