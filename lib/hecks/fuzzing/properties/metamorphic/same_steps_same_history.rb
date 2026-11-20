# frozen_string_literal: true

module Hecks
  module Fuzzing
    module Properties
      module Metamorphic
        # The same steps give the same history: two fresh sessions, each minting its ids from its
        # own counter, answer every step alike and end with the same instances. The serve form of
        # the Ruby battery's `replay_is_deterministic`.
        module SameStepsSameHistory
          module_function

          # Plays the steps in two sessions and compares the replies and the stores.
          #
          # @param probe [Probe] a greeted serve connection
          # @param steps [Array<Hash>] playable steps
          # @return [true, String] true, or the first step whose answer differed
          def call(probe, steps)
            first, second = Array.new(2) { history(probe, steps) }
            return true if first == second

            index = first[:replies].zip(second[:replies]).index { |one, other| one != other }
            index ? "step #{index} answered differently in two sessions" : "two sessions ended with different stores"
          end

          # @return [Hash] the replies and the final instances of one fresh session
          def history(probe, steps)
            probe.session { |name| { replies: probe.play(name, steps).map(&:reply), instances: probe.instances(name) } }
          end
        end
      end
    end
  end
end
