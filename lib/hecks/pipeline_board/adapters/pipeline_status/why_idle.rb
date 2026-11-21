# frozen_string_literal: true

require_relative "../rules"
require_relative "../pipeline_stages/glance_flowing"

module Hecks
  module Adapters
    module PipelineBoard
      # The status's first line: why nothing is starting. The `Idle reason` verdict rows pick the
      # state and the `IdleReason` rows give its words and the setting that governs it; this module
      # only counts what the fill and admission readers answered and names the reading's source.
      module WhyIdle
        module_function

        # @param data [Hash] the board's sections as read, with the standing `load_guard`
        # @param minutes [Integer, nil] minutes since the newest Work item started, nil when unread
        # @return [Hash] `why_idle`, `why_source` and `governed_by`, empty while work starts
        def of(data, minutes)
          reasons = GlanceFlowing.overload_reasons(data)
          state = Rules.verdict("Idle reason", measures(data, reasons))
          return { why_idle: "", why_source: "", governed_by: "" } if state == "starting"

          row = Rules.rows("IdleReason").find { |held| held[:state] == state }
          { why_idle: line(row, state, data, reasons, minutes), why_source: source(state, data), governed_by: row[:governed_by] }
        end

        # @return [Hash{Symbol => Integer, nil}] what the verdict rows compare
        def measures(data, reasons)
          fill = read(data[:fill])
          { standing: GlanceFlowing.standing(data, reasons), would: fill && Array(fill[:would_start]).size,
            skipped: fill && Array(fill[:skipped]).size, planned: fill && 1 }
        end

        # @return [Hash, nil] the fill report, nil when it was not read
        def read(fill) = fill.is_a?(Hash) && !fill.key?(:unknown) ? fill : nil

        def line(row, state, data, reasons, minutes)
          held = state == "admission closed" ? reasons.join("; ") : skips(data[:fill])
          format(row[:says], minutes: minutes || "?", what: waiting(data[:fill]), why: held)
        end

        # @return [String] the planned items the reason holds, by slug
        def waiting(fill)
          slugs = read(fill) ? Array(fill[:would_start]).map { |item| item[:slug] } : []
          slugs.empty? ? "the queue" : slugs.join(", ")
        end

        # @return [String] each skipped item and its reason, the first three
        def skips(fill)
          rows = read(fill) ? Array(fill[:skipped]) : []
          rows.first(3).map { |item| "#{item[:slug]}: #{item[:reason]}" }.join("; ")
        end

        def source(state, data)
          return "overloads and load guard" if state == "admission closed"

          at = read(data[:fill])&.dig(:at)
          at ? "fill report at #{at}" : "no fill report"
        end
      end
    end
  end
end
