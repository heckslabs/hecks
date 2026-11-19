# frozen_string_literal: true

module Hecks
  module Adapters
    class Dispatching
      # The owner's switch for admission by headroom (ADR 0222, phase 3, admission): the Tickets
      # world's `admission` line. On, a fill and the `WorkLimits` port admit each coder through
      # Signalbox's `Admission.Admit` instead of the cap; off, the cap and the red reserve hold.
      module AdmissionSwitch
        # The world verb that carries the switch.
        VERB = "admission"

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
