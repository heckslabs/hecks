# frozen_string_literal: true

require "hecks/roundhouse/adapters/metering"

module Hecks
  module Adapters
    class Dispatching
      # The owner's switch that moves Delegate's readers of load to Roundhouse's meter (ADR 0222,
      # phase 3, metering): the Tickets world's `metering` line, `roundhouse:` on or off, turned
      # with `hecks Dial.turn! setting.value=metering.roundhouse`. Off when the world names none,
      # so `uptime` stays the source until the switch is turned. The crossing is declared on
      # Roundhouse's `Metering` port, whose `Load` query this reads.
      module MeterSwitch
        # The world verb that carries the switch.
        VERB = "metering"
        # Roundhouse's load is in hundredths of a load average.
        HUNDREDTHS = 100.0

        module_function

        # @param registry [Runtime::Registry, nil] the booted registry whose Tickets world is read
        # @return [Boolean] whether the switch is on
        def on?(registry)
          declared = registry&.world("Tickets")&.for_verb(VERB)
          declared.is_a?(Hash) && declared.transform_keys(&:to_sym)[:roundhouse] == true
        end

        # @param meter [#load_facts] Roundhouse's `Metering` adapter; a live one when nil
        # @return [Float, nil] the 1-minute load the meter reads; nil when it could not read one
        def load(meter = nil)
          hundredths = (meter || Metering.new).load_facts[:load]
          hundredths && (hundredths / HUNDREDTHS)
        end
      end
    end
  end
end
