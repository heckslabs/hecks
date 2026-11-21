# frozen_string_literal: true

require_relative "tile_kit"
require_relative "../rules"

module Hecks
  module Adapters
    module PipelineBoard
      # The tile that reads the launcher's boots: the hours they have taken today (a reading, set
      # against the Tickets world's `cpu_budget` line), who booted in the last hour, the load
      # average against the limit a fill stops at, and the signals that hold a fill: it fails on a
      # boot storm and asks for attention while the boot share is over its mark.
      module BootTiles
        include TileKit

        extend BootTiles

        # How many callers the detail line names.
        CALLERS_SHOWN = 3

        # @param reading [Hash] what the `Boots` reader answered, or `{unknown: reason}`
        # @return [Hash] the tile
        def boots(reading)
          return unknown_tile("boots", "Boot hours today", reading) unless reading.is_a?(Hash) && !reading.key?(:unknown)

          tile("boots", "Boot hours today", reading[:hours].round(2), "h",
               state: boot_state(reading), detail: detail(reading))
        end

        private

        # A boot storm fails the tile; a boot share over its mark at a load over the limit asks for
        # attention; the day's hours alone never change it.
        def boot_state(reading)
          return "failed" if reading[:storms].to_h.any?

          reading[:share].to_f > reading[:share_mark].to_f && reading[:load] > reading[:max_load] ? "attention" : "ok"
        end

        def detail(reading)
          [budget_part(reading), "#{reading[:boots]} boots#{unmeasured_part(reading)}", last_hour_part(reading[:last_hour]),
           "load #{reading[:load]} of #{reading[:max_load]}", *signal_parts(reading)].join("; ")
        end

        # The boot share, and each caller storming, when there are any.
        def signal_parts(reading)
          storms = reading[:storms].to_h.map { |name, count| "storm #{name} #{count}" }
          [("boot share #{reading[:share]}%" if reading[:share]), *storms].compact
        end

        def budget_part(reading) = reading[:budget] ? "budget #{reading[:budget]} h" : "no budget set"

        # What qualifies the boot count: runs nobody measured, runs placed by their day alone, and a
        # window the byte limit cut short.
        def unmeasured_part(reading)
          notes = [("#{reading[:unmeasured]} unmeasured" if reading[:unmeasured].to_i.positive?),
                   ("#{reading[:approximate]} placed by day" if reading[:approximate].to_i.positive?),
                   ("window truncated" if reading[:truncated])].compact
          notes.empty? ? "" : " (#{notes.join(", ")})"
        end

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
