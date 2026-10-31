module RuboCop
  module Cop
    module Hecks
      # Flags a `lifecycle :x` whose owner (the nearest `aggregate` or `entity`) declares no
      # `attribute :x`. A lifecycle moves a value that its owner must hold.
      #
      # @example
      #   lifecycle :status, default: "open" do   # bad unless `attribute :status`
      #   end
      class LifecycleNeedsAttribute < Base
        MSG = "`lifecycle :%<name>s` has no state to hold: `%<owner>s` declares no " \
              "`attribute :%<name>s`. Declare the attribute the lifecycle tracks.".freeze
        OWNERS = %i[aggregate entity].freeze

        # Flags a lifecycle whose owner declares no attribute of the same name.
        #
        # @param node [RuboCop::AST::SendNode] the `lifecycle` call being visited
        # @return [void]
        def on_send(node)
          return unless node.receiver.nil? && node.method_name == :lifecycle
          return unless node.first_argument&.sym_type?

          owner = owner_block(node)
          return unless owner

          name = node.first_argument.value
          return if attribute_names(owner).include?(name)

          add_offense(node, message: format(MSG, name: name, owner: owner.send_node.first_argument.value))
        end

        private

        def owner_block(node)
          node.each_ancestor(:block).find do |block|
            OWNERS.include?(block.method_name) && block.send_node.receiver.nil?
          end
        end

        def attribute_names(owner)
          direct_statements(owner).filter_map do |statement|
            next unless statement.send_type? && statement.method_name == :attribute
            next unless statement.first_argument&.sym_type?

            statement.first_argument.value
          end
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
