module RuboCop
  module Cop
    module Hecks
      # Flags a direct wall-clock read (`Time.now`, `Date.today`, `Time.current`) in the runtime.
      #
      # The runtime must stay replayable (ADR 0081), so time reaches a command through `needs :now`
      # or through the one stamping seam, `Hecks::Runtime::Event.stamp`; a stray read makes a
      # replay differ from the original run and cannot be pinned in a test.
      #
      # @example
      #   Event.new(name: n, occurred_at: Time.now.utc.iso8601)  # bad
      #   Event.new(name: n, occurred_at: Event.stamp)           # good
      class NoWallClockInRuntime < Base
        MSG = "`%<call>s` reads the wall clock inside the runtime, so a replay cannot reproduce it. " \
              "Declare `needs :now` on the command, or stamp an event with `Hecks::Runtime::Event.stamp`.".freeze

        # @!method wall_clock_read?(node)
        def_node_matcher :wall_clock_read?, <<~PATTERN
          (send (const {nil? cbase} {:Time :Date :DateTime}) {:now :today :current})
        PATTERN

        # Flags a `Time.now`-style call.
        #
        # @param node [RuboCop::AST::SendNode] the call being visited
        # @return [void]
        def on_send(node)
          return unless wall_clock_read?(node)

          add_offense(node, message: format(MSG, call: node.source))
        end
      end
    end
  end
end
