module RuboCop
  module Cop
    module Hecks
      # Flags a `value_object` block whose whole body is one `attribute :value, Type`, and asks
      # for the bare shorthand `value_object "Name", Type` instead. A block with an invariant, a
      # second attribute, or an option is left alone: the shorthand cannot carry those.
      #
      # @example
      #   value_object "BookCopies" do            # bad
      #     attribute :value, Integer
      #   end
      #
      #   value_object "BookCopies", Integer      # good
      class InlineSingleFieldValueObject < Base
        extend AutoCorrector

        MSG = "A value object whose only line is `attribute :value, %<type>s` is declared by the " \
              "shorthand `value_object \"%<name>s\", %<type>s`; the block adds nothing. Inline it, " \
              "or keep the block if it needs an invariant or an option.".freeze

        # @!method value_object_block?(node)
        def_node_matcher :value_object_block?, <<~PATTERN
          (block (send nil? :value_object (str $_)) (args) (send nil? :attribute (sym :value) $_))
        PATTERN

        # Flags a `value_object` block whose body is only a bare `attribute :value, Type`, and
        # rewrites it to the shorthand.
        #
        # @param node [RuboCop::AST::BlockNode] the block being visited
        # @return [void]
        def on_block(node)
          name, type = value_object_block?(node)
          return unless name && type && type.type == :const

          add_offense(node, message: format(MSG, name: name, type: type.source)) do |corrector|
            corrector.replace(node, %(value_object "#{name}", #{type.source}))
          end
        end
      end
    end
  end
end
