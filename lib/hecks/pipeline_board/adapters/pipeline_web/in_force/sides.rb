# frozen_string_literal: true

module Hecks
  module Adapters
    module PipelineBoard
      module InForce
        # Which side governs each of the four things a start turns on, said in one sentence each.
        module Sides
          module_function

          # @param dials [Array<Hash>] the settings rows
          # @param reading [Hash] {InForce.reading}
          # @return [Hash{Symbol => Hash}] `load`, `admission`, `protection` and `reaping`, each
          #   with the `side` (Signalbox or Tickets) and what it `says`
          def of(dials, reading)
            value = ->(name) { dials.find { |dial| dial[:setting] == name }&.fetch(:value, nil) }
            { load: load(reading, value), admission: admission(reading, value),
              protection: switched(reading, "protection", "Its breakers hold new coders.", "The boot fuse (cpu_budget) holds."),
              reaping: switched(reading, "reaping", "Each reap is ruled on Roundhouse's meter.", "The plain sweep reaps.") }
          end

          def load(reading, value)
            signal = reading[:signal]
            return side("Signalbox", "A start waits while the band is short (#{signal[:band]} now).") if signal

            side("Tickets", "A start waits above a load of #{value.call("dispatch_max_load.limit")}. #{Switches.dark(reading)}")
          end

          def admission(reading, value)
            return side("Signalbox", "Each coder is admitted by headroom.") if Rules.admitted?(reading)

            cap = reading[:moving]&.fetch(:current) || value.call("work_limit.cap")
            side("Tickets", "At most #{cap} Work items start at once, with the red reserve.")
          end

          def switched(reading, verb, signalbox, tickets)
            Rules.on?(reading, verb, :signalbox) ? side("Signalbox", signalbox) : side("Tickets", tickets)
          end

          def side(who, says) = { side: who, says: says }
        end
      end
    end
  end
end
