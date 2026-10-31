module RuboCop
  module Cop
    module Hecks
      # Flags a plain-string attribute that holds another record's id, such as
      # `attribute :teacher_id, String`. Declare `reference_to` so the domain holds the record.
      # A query's argument is exempt: `attribute :author_id, String` names a caller's value.
      #
      # @example
      #   attribute :teacher_id, String          # bad
      #   reference_to Person, as: :teacher      # good
      #
      #   query "ByAuthor" do
      #     attribute :author_id, String         # good: a caller's argument
      #     where author: :author_id
      #   end
      class NoIdStringAttribute < Base
        MSG = "`%<name>s` stores another record's id as a string. Declare `reference_to %<target>s, as: :%<role>s` " \
              "so the domain holds the reference, and let the adapter map the school's ids.".freeze

        # @!method id_string_attribute?(node)
        def_node_matcher :id_string_attribute?, <<~PATTERN
          (send nil? :attribute $(sym _) (const nil? :String))
        PATTERN

        # Flags an `attribute :x_id, String` declared outside a `query`.
        #
        # @param node [RuboCop::AST::SendNode] the call being visited
        # @return [void]
        def on_send(node)
          id_string_attribute?(node) do |name_node|
            name = name_node.value.to_s
            return unless name.end_with?("_id")
            return if inside_query?(node)

            role = name.delete_suffix("_id")
            add_offense(node, message: format(MSG, name: name, target: role.capitalize, role: role))
          end
        end

        private

        # True when the attribute sits in a `query` block, at any depth.
        def inside_query?(node)
          node.each_ancestor(:block).any? { |block| block.method_name == :query }
        end
      end
    end
  end
end
