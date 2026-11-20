# frozen_string_literal: true

module Hecks
  module Adapters
    class Dispatching
      # The owner's switch for protection (ADR 0222, phase 3, protection): the Tickets world's
      # `protection` line. On, a fill's boot-budget hold is Signalbox's breakers, tripped in the
      # order its `Breaker` Order rows declare; off, the `cpu_budget` boot fuse holds as before.
      module ProtectionSwitch
        # The world verb that carries the switch.
        VERB = "protection"

        module_function

        # @param registry [Runtime::Registry, nil] whose Tickets world is read
        # @return [Boolean] true only when the world says `signalbox: true`
        def on?(registry)
          declared = registry&.world("Tickets")&.for_verb(VERB)
          declared.is_a?(Hash) && declared.transform_keys(&:to_sym)[:signalbox] == true
        rescue StandardError
          false
        end
      end
    end
  end
end
