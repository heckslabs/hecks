module RuboCop
  module Cop
    module Hecks
      # Flags a broad `rescue` whose whole body is `nil`, `false` or `next`.
      #
      # A bare `rescue` or `rescue StandardError` that answers a literal turns any crash into an
      # ordinary "no result". Rescuing a named error is left alone; a deliberate guard goes
      # through `Hecks::Runtime::BestEffort.call(default) { ... }`.
      #
      # @example
      #   adapter.capable? rescue false                           # bad
      #   BestEffort.call(false) { adapter.capable? }             # good
      class SwallowedRescue < Base
        MSG = "This broad `rescue` answers `%<answer>s` for any failure, so a crash reads as an ordinary " \
              "\"no result\". Rescue the specific error, or use `Runtime::BestEffort.call(default) { ... }` " \
              "for a deliberate guard.".freeze

        # @!method swallowed_answer(node)
        def_node_matcher :swallowed_answer, <<~PATTERN
          (resbody {nil? (array (const {nil? cbase} {:StandardError :Exception}))} _
            ${(nil) (false) (next)})
        PATTERN

        # Flags a broad rescue clause that answers a bare literal.
        #
        # @param node [RuboCop::AST::ResbodyNode] the rescue clause being visited
        # @return [void]
        def on_resbody(node)
          answer = swallowed_answer(node)
          return unless answer

          add_offense(node, message: format(MSG, answer: answer.source))
        end
      end
    end
  end
end
