module RuboCop
  module Cop
    module Hecks
      # Flags a creating command's attribute that no `sets` copies onto the aggregate. A command
      # with no `reference_to` to its own aggregate creates one, so each attribute must be set.
      #
      # @example
      #   command "Print" do
      #     attribute :ref, StickerRef     # bad unless `sets :ref`
      #   end
      class CreatingCommandSets < Base
        MSG = "Command `%<command>s` creates its aggregate, so its attribute `%<name>s` must be set " \
              "onto it. Add `sets :%<name>s`.".freeze

        # Flags each attribute of a creating command with no matching `sets`.
        #
        # @param node [RuboCop::AST::BlockNode] the command block being visited
        # @return [void]
        def on_block(node)
          return unless node.send_node.receiver.nil? && node.method_name == :command

          aggregate = owner_aggregate(node)
          return unless aggregate
          return if references_own_aggregate?(node, aggregate.send_node.first_argument.value)

          unset_attributes(node).each { |statement, name| flag(statement, node, name) }
        end

        private

        def owner_aggregate(node)
          node.each_ancestor(:block).find { |block| block.method_name == :aggregate }
        end

        def flag(statement, node, name)
          command = node.send_node.first_argument.value
          add_offense(statement, message: format(MSG, command: command, name: name))
        end

        # Each `attribute :x` of the command whose `sets :x` is missing, with its name.
        def unset_attributes(node)
          statements = direct_statements(node)
          sets = statements.filter_map { |statement| symbol_argument(statement, :sets) }
          statements.filter_map do |statement|
            name = symbol_argument(statement, :attribute)
            [statement, name] if name && !sets.include?(name)
          end
        end

        def references_own_aggregate?(node, aggregate_name)
          direct_statements(node).any? do |statement|
            statement.send_type? && statement.method_name == :reference_to &&
              statement.first_argument&.const_type? &&
              statement.first_argument.const_name == aggregate_name
          end
        end

        # The symbol a one-argument call names, as in `sets :ref` or `attribute :ref, Type`.
        def symbol_argument(statement, method)
          return unless statement.send_type? && statement.method_name == method
          return unless statement.first_argument&.sym_type?

          statement.first_argument.value
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
