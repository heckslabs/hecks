# frozen_string_literal: true

module Hecks
  module Adapters
    class MachineSampling
      # The owner's bounds on the moving work cap, as the Tickets world's `work_cap` line sets
      # them: reported beside each reading so the `WorkCap` bluebook holds the cap inside them. It
      # reads a setting and judges nothing.
      class CapBounds
        # The world verb that carries the bounds and the switch between a moving and a fixed cap.
        VERB = "work_cap"

        # The bounds when the world says none.
        DEFAULTS = { least: 2, most: 10 }.freeze

        # @param registry [Runtime::Registry, nil] the booted registry whose Tickets world is read
        # @return [Hash{Symbol => Integer}] `cap_least` and `cap_most`, the world's over defaults
        def self.of(registry)
          bounds = DEFAULTS.merge(declared(registry).slice(*DEFAULTS.keys).compact) { |_key, _default, given| Integer(given) }
          { cap_least: bounds[:least], cap_most: bounds[:most] }
        end

        # @param registry [Runtime::Registry, nil]
        # @return [Boolean] whether the owner has the cap move with the machine (`moves: true`)
        def self.moving?(registry) = declared(registry)[:moves] == true

        # @param registry [Runtime::Registry, nil]
        # @return [Hash] the world's `work_cap` line, empty when it declares none
        def self.declared(registry) = registry&.world("Tickets")&.for_verb(VERB) || {}
      end
    end
  end
end
