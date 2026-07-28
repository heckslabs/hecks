require "prism"

module Hecksagain
  module Adapters
    class NotExtractable < StandardError; end

    module Prism
      TREES = {}

      module_function

      def canonical(block)
        body = body_source(block)
        body && canonicalise(body)
      end

      def body_source(block)
        file, line = block.source_location
        return nil unless file && File.readable?(file)

        node = block_node_at(file, line)
        node&.body&.slice
      end

      def block_node_at(file, line)
        found = nil
        walk(tree_for(file)) do |node|
          next unless node.is_a?(::Prism::BlockNode)
          next unless node.location.start_line == line

          found ||= node
        end
        found
      end

      def tree_for(file)
        TREES[file] ||= ::Prism.parse_file(file).value
      end

      def walk(node, &visit)
        return unless node.is_a?(::Prism::Node)

        visit.call(node)
        node.compact_child_nodes.each { |child| walk(child, &visit) }
      end

      def canonicalise(source)
        Bluebook::Expression::CanonicalForm.apply(source)
      end
    end
  end
end
