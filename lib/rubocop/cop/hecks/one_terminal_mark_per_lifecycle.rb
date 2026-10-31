module RuboCop
  module Cop
    module Hecks
      # Flags a second `mark :terminal` line in one lifecycle. A lifecycle names its terminal states
      # once, on one line, so the set reads in one place and a state cannot be left out of it.
      #
      # @example
      #   lifecycle :status, default: "open" do
      #     mark :terminal, "closed"
      #     mark :terminal, "void"                  # bad
      #   end
      #
      #   lifecycle :status, default: "open" do
      #     mark :terminal, "closed", "void"        # good
      #   end
      class OneTerminalMarkPerLifecycle < Base
        MSG = "A lifecycle takes one `mark :terminal` line. Name every terminal state on that line, as " \
              "`mark :terminal, \"a\", \"b\"`.".freeze

        # Flags every `mark :terminal` after the first in a lifecycle block.
        #
        # @param node [RuboCop::AST::BlockNode] the lifecycle block being visited
        # @return [void]
        def on_block(node)
          return unless node.send_node.receiver.nil? && node.method_name == :lifecycle

          marks = direct_statements(node).select { |statement| terminal_mark?(statement) }
          marks.drop(1).each { |mark| add_offense(mark, message: MSG) }
        end

        private

        def terminal_mark?(node)
          node.send_type? && node.method_name == :mark &&
            node.first_argument&.sym_type? && node.first_argument.value == :terminal
        end

        def direct_statements(block)
          body = block.body
          return [] unless body

          body.begin_type? ? body.children : [body]
        end
      end
    end
  end
end
