module Hecks
  module Bluebook
    module ModelCheck
      # The loops of a reaction graph: groups of policies that can each reach the others through
      # the commands they dispatch (the strongly connected components with a cycle in them, found
      # with Tarjan's algorithm), whether or not any command outside the group starts them.
      class ReactionCycles
        # @param policies [Array] the graph's nodes, in declaration order
        # @param successors [Hash{Object => Array}] the policies each policy's dispatch can start
        def initialize(policies, successors)
          @policies   = policies
          @successors = successors
        end

        # @return [Array<Array>] each loop's policies, in declaration order
        def groups
          @index = {}
          @low = {}
          @stack = []
          @found = []
          @policies.each { |policy| connect(policy) unless @index.key?(policy) }
          @found.select { |group| loop?(group) }.map { |group| group.sort_by { |policy| @policies.index(policy) } }
        end

        private

        def loop?(group) = group.size > 1 || @successors.fetch(group.first).include?(group.first)

        def connect(node)
          @index[node] = @low[node] = @index.size
          @stack.push(node)
          @successors.fetch(node).each { |next_node| visit(node, next_node) }
          @found << pop_group(node) if @low[node] == @index[node]
        end

        def visit(node, next_node)
          if @index.key?(next_node)
            @low[node] = [@low[node], @index[next_node]].min if @stack.include?(next_node)
          else
            connect(next_node)
            @low[node] = [@low[node], @low[next_node]].min
          end
        end

        def pop_group(root)
          group = []
          group << @stack.pop until group.last.equal?(root)
          group
        end
      end
    end
  end
end
