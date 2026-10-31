module RuboCop
  module Cop
    module Hecks
      # Flags a value object block that only wraps one `value` attribute with no invariant.
      # The shorthand says the same thing in one line: `value_object "Name", Type`.
      #
      # A block with an invariant, or with any other attribute, is left alone: the block is the
      # only place an invariant can go.
      #
      # @example
      #   value_object "EmailAddress" do            # bad
      #     attribute :value, String
      #   end
      #
      #   value_object "EmailAddress", String       # good
      class ValueObjectShorthand < Base
        MSG = "`value_object \"%<name>s\"` holds one value with no invariant, so declare it as " \
              "`value_object \"%<name>s\", %<type>s`.".freeze

        # Flags a `value_object` block whose whole body is `attribute :value, Type`.
        #
        # @param node [RuboCop::AST::BlockNode] the block being visited
        # @return [void]
        def on_block(node)
          return unless value_object_block?(node)
          return unless single_value_attribute?(node.body)

          send = node.send_node
          add_offense(send, message: offense_message(send, node.body))
        end

        private

        # A `value_object "Name"` call with no receiver and a string name.
        def value_object_block?(node)
          send = node.send_node
          send.receiver.nil? && send.method_name == :value_object && send.first_argument&.str_type?
        end

        def offense_message(send, body)
          type = body.arguments.last.const_name || body.arguments.last.source
          format(MSG, name: send.first_argument.value, type: type)
        end

        # The body is exactly one `attribute :value, Type` call.
        def single_value_attribute?(body)
          return false unless body&.send_type?
          return false unless body.method_name == :attribute && body.arguments.size == 2

          name, type = body.arguments
          name.sym_type? && name.value == :value && type.const_type?
        end
      end
    end
  end
end
