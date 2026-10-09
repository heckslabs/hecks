module RuboCop
  module Cop
    module Hecks
      # Flags `raise "message"` and `raise RuntimeError, "message"`.
      #
      # A bare string raises a `RuntimeError`, so a caller can only rescue it by rescuing
      # everything. A named error class lets the caller rescue exactly this refusal and lets the
      # message change without breaking the rescue.
      #
      # @example
      #   raise "no clock adapter bound"                       # bad
      #   raise WiringError, "no clock adapter bound"          # good
      class UntypedRaise < Base
        MSG = "`%<call>s` raises a bare `RuntimeError`, which a caller can only rescue by rescuing " \
              "everything. Raise a named error class.".freeze

        RESTRICT_ON_SEND = %i[raise fail].freeze

        # @!method untyped?(node)
        def_node_matcher :untyped?, <<~PATTERN
          {(send nil? {:raise :fail} {str dstr})
           (send nil? {:raise :fail} (const {nil? cbase} :RuntimeError) ...)}
        PATTERN

        # Flags a raise with no named error class.
        #
        # @param node [RuboCop::AST::SendNode] the raise being visited
        # @return [void]
        def on_send(node)
          return unless untyped?(node)

          add_offense(node, message: format(MSG, call: node.method_name))
        end
      end
    end
  end
end
