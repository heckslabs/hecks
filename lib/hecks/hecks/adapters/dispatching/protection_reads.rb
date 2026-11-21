# frozen_string_literal: true

require_relative "protection_switch"
require_relative "protecting"

module Hecks
  module Adapters
    class Dispatching
      # What a filling reads of protection: with the owner's `protection.signalbox` switch on, the
      # boot-share hold is Signalbox's breakers ({Protecting}), so the machine fuse holds new
      # coders only once no smaller breaker can act, and the header names the breaker that acts
      # first. Off, the boot share fuse ({Settings#boot_stop}) holds as before. It reads the
      # registry, machine and stand-ins of the {Dispatching} that includes it; `protecting:` stands
      # in.
      module ProtectionReads
        private

        # @return [String, nil] why every coder waits on a fuse, nil when none holds them
        def fuse_stop = protecting ? protecting.stop : machine.boot_stop

        # @return [Hash] the plan's boot holds: `budget:` why every coder waits, `storm:` why one
        #   item's own run waits
        def protection_limits = { budget: fuse_stop, storm: machine.method(:storm_reason) }

        # @return [String] `; <the protection clause>` with the switch on, else nothing
        def protection_clause = protecting ? "; #{protecting.clause}" : ""

        def protecting
          return @standins[:protecting] if @standins.key?(:protecting)
          return unless ProtectionSwitch.on?(@registry)

          @protecting ||= Protecting.new(share:    machine.method(:boot_share_reading),
                                         sessions: -> { Metering.new(registry: @registry).rows })
        end
      end
    end
  end
end
