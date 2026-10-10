module RuboCop
  module Cop
    module Hecks
      # Flags a fixed `sleep` in a spec.
      #
      # A fixed sleep is a guess about how long another thread needs: too short and the example is
      # flaky, too long and the suite is slow. Wait on the thing itself instead, with a Queue, a
      # latch, or `ThreadParking.wait_until_parked(thread)` when the assertion is "still blocked".
      #
      # @example
      #   sleep 0.2                                   # bad
      #   ThreadParking.wait_until_parked(waiter)     # good
      class SleepInSpec < Base
        MSG = "A fixed `sleep` guesses how long another thread needs, so the example is either flaky or " \
              "slow. Wait on the thread itself: a Queue, or `ThreadParking.wait_until_parked(thread)`.".freeze

        RESTRICT_ON_SEND = %i[sleep].freeze

        # @!method fixed_sleep?(node)
        def_node_matcher :fixed_sleep?, <<~PATTERN
          (send {nil? (const {nil? cbase} :Kernel)} :sleep ...)
        PATTERN

        # Flags a `sleep` call.
        #
        # @param node [RuboCop::AST::SendNode] the call being visited
        # @return [void]
        def on_send(node)
          add_offense(node, message: MSG) if fixed_sleep?(node)
        end
      end
    end
  end
end
