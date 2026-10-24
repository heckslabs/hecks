module RuboCop
  module Cop
    module Hecks
      # Flags a chain of more than three calls: `text.to_s.strip.downcase.gsub(SEPARATORS, "_")`.
      #
      # A long pipeline makes the reader replay every step to learn what comes out. Extract it into
      # a method named for the result (`slug(text)`, `first_line(error)`), and reuse that method
      # where the same pipeline appears again. The receiver does not count toward the limit.
      #
      # @example
      #   error.message.lines.first.to_s.strip      # bad
      #   first_line(error.message)                 # good
      class UnnamedPipeline < Base
        MSG = "This chain runs %<count>d calls; a reader has to replay each one to learn what it makes. " \
              "Extract it into a method named for the result.".freeze

        # Flags the outermost call of a chain longer than `MaxCalls`.
        #
        # @param node [RuboCop::AST::SendNode] the call being visited
        # @return [void]
        def on_send(node)
          return if chained_further?(node)

          count = chain_length(node)
          add_offense(node, message: format(MSG, count: count)) if count > cop_config.fetch("MaxCalls", 3)
        end
        alias on_csend on_send

        private

        def chained_further?(node)
          outer = node.block_literal? ? node.parent : node
          outer.parent&.call_type? && outer.parent.receiver.equal?(outer)
        end

        def chain_length(node)
          count = 0
          while (node = link(node))&.call_type? && node.receiver && !node.operator_method?
            count += 1
            node = node.receiver
          end
          count
        end

        def link(node)
          node&.any_block_type? ? node.send_node : node
        end
      end
    end
  end
end
