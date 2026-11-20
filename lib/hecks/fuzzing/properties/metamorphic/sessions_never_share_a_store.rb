# frozen_string_literal: true

module Hecks
  module Fuzzing
    module Properties
      module Metamorphic
        # Sessions never share a store: a session opened beside one that plays the steps holds no
        # records after the other one has written.
        module SessionsNeverShareAStore
          module_function

          # Opens a bystander session, plays the steps in a second one, and reads the bystander.
          #
          # @param probe [Probe] a greeted serve connection
          # @param steps [Array<Hash>] playable steps
          # @return [true, String] true, or how many records the bystander came to hold
          def call(probe, steps)
            probe.session do |bystander|
              probe.session { |player| probe.play(player, steps) }
              held = probe.instances(bystander).values.sum { |records| Array(records).size }
              held.zero? || "a session that played nothing holds #{held} records another session wrote"
            end
          end
        end
      end
    end
  end
end
