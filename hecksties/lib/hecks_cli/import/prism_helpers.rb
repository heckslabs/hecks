# Hecks::Import::PrismHelpers
#
# Mixin providing low-level Prism AST node accessors shared by
# ModelParser's extraction methods. Not intended for direct use.
#
#   include Hecks::Import::PrismHelpers
#   first_symbol_arg(call_node)   # => "restaurant"
#   kwarg_symbol(call_node, :through)  # => "order_items"
#
module Hecks
  module Import
    module PrismHelpers
      def first_symbol_arg(call)
        args = call.arguments&.arguments || []
        node = args.first
        node.is_a?(Prism::SymbolNode) ? node.unescaped : nil
      end

      # Returns the string value of a keyword argument whose key matches +key+.
      def kwarg_symbol(call, key)
        each_kwarg(call) do |k, v|
          return v.unescaped if k == key.to_s && v.is_a?(Prism::SymbolNode)
        end
        nil
      end

      def kwarg_true?(call, key)
        each_kwarg(call) do |k, v|
          next unless k == key.to_s
          return true if v.is_a?(Prism::TrueNode)
          return true if v.is_a?(Prism::SymbolNode) || v.is_a?(Prism::HashNode)
        end
        false
      end

      # Yields [key_string, value_node] for each keyword argument on +call+.
      def each_kwarg(call)
        args = call.arguments&.arguments || []
        args.each do |arg|
          next unless arg.is_a?(Prism::KeywordHashNode)
          arg.elements.each do |el|
            next unless el.is_a?(Prism::AssocNode)
            key = el.key
            k = case key
                when Prism::SymbolNode then key.unescaped
                when Prism::StringNode then key.unescaped
                else nil
                end
            yield k, el.value if k
          end
        end
      end

      # Collect kwargs as { "key" => value_node } hash.
      def collect_kwargs(call)
        result = {}
        each_kwarg(call) { |k, v| result[k] = v }
        result
      end

      # Return the direct CallNode children inside a call's block body.
      def block_calls(call)
        block = call.block
        return [] unless block.is_a?(Prism::BlockNode)
        body = block.body
        return [] unless body.is_a?(Prism::StatementsNode)
        body.body.select { |n| n.is_a?(Prism::CallNode) }
      end
    end
  end
end
