# frozen_string_literal: true

require_relative "tile_kit"

module Hecks
  module Adapters
    module PipelineBoard
      # The tile that reads the launcher's boots: the hours they have taken today against the
      # budget the Tickets world's `cpu_budget` line sets, who booted in the last hour, and the
      # load average against the limit a fill stops at.
      module BootTiles
        include TileKit

        extend BootTiles

        # The share of the budget at which the tile asks for attention.
        ATTENTION_SHARE = 0.8

        # How many callers the detail line names.
        CALLERS_SHOWN = 3

        # @param reading [Hash] what the `Boots` reader answered, or `{unknown: reason}`
        # @return [Hash] the tile
        def boots(reading)
          return unknown_tile("boots", "Boot hours today", reading) unless reading.is_a?(Hash) && !reading.key?(:unknown)

          tile("boots", "Boot hours today", reading[:hours].round(2), "h",
               state: boot_state(reading[:hours], reading[:budget]), detail: detail(reading))
        end

        private

        def boot_state(hours, budget)
          return "ok" if budget.nil?
          return "failed" if hours >= budget

          hours >= budget * ATTENTION_SHARE ? "attention" : "ok"
        end

        def detail(reading)
          [budget_part(reading), "#{reading[:boots]} boots#{unmeasured_part(reading)}", last_hour_part(reading[:last_hour]),
           "load #{reading[:load]} of #{reading[:max_load]}"].join("; ")
        end

        def budget_part(reading) = reading[:budget] ? "budget #{reading[:budget]} h" : "no budget set"

        def unmeasured_part(reading) = reading[:unmeasured].positive? ? " (#{reading[:unmeasured]} unmeasured)" : ""

        def last_hour_part(callers)
          return "none in the last hour" if callers.empty?

          shown = callers.first(CALLERS_SHOWN).map { |name, count| "#{name} #{count}" }
          "last hour: #{(shown + more(callers)).join(", ")}"
        end

        def more(callers) = callers.size > CALLERS_SHOWN ? ["+#{callers.size - CALLERS_SHOWN}"] : []
      end
    end
  end
end
