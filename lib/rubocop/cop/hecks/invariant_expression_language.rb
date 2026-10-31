module RuboCop
  module Cop
    module Hecks
      # Flags a call the bluebook expression language cannot evaluate, inside an `invariant` or
      # `given` block. The language refuses these with "the expression language cannot evaluate",
      # so the bluebook fails at boot, not where the check was written.
      #
      # The language compares with `==`, `!=` and `>=`, joined by `||` and `&&`.
      #
      # @example
      #   invariant("a flag is yes or no") { value.include?("yes") }    # bad
      #   invariant("a flag is yes or no") { value == "yes" || value == "no" }   # good
      #   invariant("a name is present") { name.empty? }                # bad
      #   invariant("a name is present") { name != "" }                 # good
      class InvariantExpressionLanguage < Base
        MSG = "`%<source>s` is outside the expression language, which cannot evaluate it. Spell the " \
              "test out: `==` joined by `||` for a set of values, or `!= \"\"` for a non-empty test.".freeze

        CHECKED_BLOCKS = %i[invariant given].freeze
        UNSUPPORTED_CALLS = %i[include? length to_s empty? between?].freeze

        # Flags an unsupported call or a `%w[...]` list in an `invariant` or `given` block.
        #
        # @param node [RuboCop::AST::BlockNode] the block being visited
        # @return [void]
        def on_block(node)
          return unless node.send_node.receiver.nil? && CHECKED_BLOCKS.include?(node.method_name)
          return unless node.body

          node.body.each_node(:send, :array) do |child|
            next unless unsupported?(child)

            add_offense(child, message: format(MSG, source: child.source))
          end
        end

        private

        def unsupported?(node)
          return node.source.start_with?("%w") if node.array_type?

          node.send_type? && UNSUPPORTED_CALLS.include?(node.method_name)
        end
      end
    end
  end
end
