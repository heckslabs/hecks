require "prism"

module Hecks
  module Bluebook
    module Merge
      # Reads the word and name of one parsed statement: `command "Place" do` is the word
      # `command` and the name `Place`, and `transition "Send" => "pushed"` the name `Send`.
      module Label
        # Words whose first argument is a message or a filter, not a name: two of them in one
        # block are told apart by where they stand, so an edit on each branch meets as one member.
        PREDICATES = %w[invariant given ensures where].freeze

        module_function

        # @param node [Prism::Node] a statement of a file or of a block
        # @return [Hash] `word:`, `name:` and `named:` for a {Member}
        def of(node)
          return { word: "ruby", name: nil, named: false } unless node.is_a?(::Prism::CallNode)

          given = arguments(node)
          first = given.first
          { word: node.name.to_s, name: first && identity(first), named: named?(node, given) }
        end

        # @api private
        def arguments(node)
          list = node.arguments
          list ? list.arguments : []
        end

        # A call names a member when it says more than one thing about it: a block, a second
        # argument, or a `name => value` pair. A lone argument (`role "Operator"`) is a value.
        # @api private
        def named?(node, given)
          return false if given.empty? || PREDICATES.include?(node.name.to_s)

          !node.block.nil? || given.size > 1 || given.first.is_a?(::Prism::KeywordHashNode)
        end

        # @api private
        def identity(node)
          node = node.elements.first if node.is_a?(::Prism::KeywordHashNode)
          node = node.key if node.is_a?(::Prism::AssocNode)
          node.respond_to?(:unescaped) ? node.unescaped : node.slice
        end
      end
    end
  end
end
