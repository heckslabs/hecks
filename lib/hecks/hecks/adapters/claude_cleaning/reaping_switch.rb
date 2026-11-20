# frozen_string_literal: true

module Hecks
  module Adapters
    class ClaudeCleaning
      # The owner's switch for reaping (ADR 0222, phase 3, reaping): the Tickets world's
      # `reaping` line, not the Hecks world's line of the same verb, which holds the keep windows
      # {PlainSweep} reads. On, a reap is Signalbox's ({SignalboxReap}); off, {PlainSweep} reaps.
      module ReapingSwitch
        # The world verb that carries the switch.
        VERB = "reaping"

        module_function

        # @param registry [Runtime::Registry, nil] whose Tickets world is read
        # @return [Boolean] true only when the Tickets world says `signalbox: true`
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
