module Hecks
  module Querying
    # Hecks::Querying::ConditionNode
    #
    # Tree structure for composing AND/OR query conditions. Leaf AND nodes
    # hold a conditions hash; OR nodes combine two child trees. Used by
    # QueryBuilder to represent composite conditions that can be arbitrarily
    # nested. Each adapter evaluates the tree via +match?(obj)+ for in-memory
    # filtering or builds its own expression (e.g., SQL WHERE clause).
    #
    # == Node Types
    #
    # - +:and+ -- all conditions and children must match. A leaf AND node has
    #   a conditions hash and no children. A compound AND node has children.
    # - +:or+ -- at least one child must match. Always has exactly two children.
    #
    # == Usage
    #
    #   node = ConditionNode.and(style: "Classic")
    #   node = node.merge(name: "Margherita")
    #   combined = ConditionNode.or(node, ConditionNode.and(style: "Tropical"))
    #   combined.match?(pizza)  # => true if either branch matches
    #
    class ConditionNode
        # @return [Symbol] the node type, either +:and+ or +:or+
        attr_reader :type

        # @return [Array<ConditionNode>] child nodes for compound conditions
        attr_reader :children

        # @return [Hash<Symbol, Object>] attribute conditions for leaf AND nodes;
        #   values may be literals or Operators::Operator instances
        attr_reader :conditions

        # Creates a leaf AND node with the given conditions hash.
        #
        # @param conditions [Hash<Symbol, Object>] attribute-value pairs to match;
        #   values can be literals (equality) or Operator instances (Gt, Lt, etc.)
        # @return [ConditionNode] a new AND node
        def self.and(conditions = {})
          new(type: :and, conditions: conditions)
        end

        # Creates an OR node combining two condition trees.
        #
        # @param left [ConditionNode] the left branch
        # @param right [ConditionNode] the right branch
        # @return [ConditionNode] a new OR node with both branches as children
        def self.or(left, right)
          new(type: :or, children: [left, right])
        end

        # Initializes a condition node.
        #
        # @param type [Symbol] the node type (+:and+ or +:or+)
        # @param conditions [Hash<Symbol, Object>] attribute conditions (for AND leaves)
        # @param children [Array<ConditionNode>] child nodes (for compound AND or OR nodes)
        def initialize(type:, conditions: {}, children: [])
          @type = type
          @conditions = conditions
          @children = children
        end

        # Merges new conditions into this node, returning a new node.
        #
        # For simple AND leaves (no children), merges the hash directly.
        # For compound nodes, wraps both in a new AND with two children.
        #
        # @param new_conditions [Hash<Symbol, Object>] conditions to add
        # @return [ConditionNode] a new node with the merged conditions
        def merge(new_conditions)
          if type == :and && children.empty?
            self.class.new(type: :and, conditions: @conditions.merge(new_conditions))
          else
            self.class.new(type: :and, children: [self, self.class.and(new_conditions)])
          end
        end

        # Returns true if this is a simple AND leaf with no children (flat hash).
        #
        # Simple nodes can be passed directly to adapter-native query methods.
        # Compound nodes require in-memory evaluation or adapter-specific tree walking.
        #
        # @return [Boolean] true if this is a flat AND node
        def simple?
          type == :and && children.empty?
        end

        # Evaluates the condition tree against an object (in-memory filtering).
        #
        # For AND nodes, all conditions and all children must match. Conditions
        # are checked by sending the attribute name to the object and comparing
        # the result -- either via equality or via the Operator's +match?+ method.
        #
        # For OR nodes, at least one child must match.
        #
        # @param obj [Object] the domain object to test; must respond to attribute
        #   names used in conditions
        # @return [Boolean] true if the object satisfies this condition tree
        def match?(obj)
          case type
          when :and
            cond_match = conditions.all? do |k, v|
              next false unless obj.respond_to?(k)
              actual = obj.send(k)
              v.is_a?(Operators::Operator) ? v.match?(actual) : actual == v
            end
            cond_match && children.all? { |c| c.match?(obj) }
          when :or
            children.any? { |c| c.match?(obj) }
          end
        end
      end
  end
end
