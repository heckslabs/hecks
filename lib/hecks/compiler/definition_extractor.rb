# Hecks::Compiler::DefinitionExtractor
#
# Prism AST visitor that extracts class and module definitions from
# a Ruby source file. Tracks the full constant path (e.g. Hecks::Compiler)
# and distinguishes namespace-only modules from real definitions.
#
#   result = DefinitionExtractor.extract(source)
#   result.definitions  # => ["Hecks::Compiler::SourceAnalyzer"]
#   result.namespaces   # => ["Hecks", "Hecks::Compiler"]
#
require "prism"

module Hecks
  module Compiler
    class DefinitionExtractor < Prism::Visitor
      Result = Struct.new(:definitions, :namespaces, keyword_init: true)

      # Extracts definitions from Ruby source code.
      #
      # @param source [String] Ruby source code
      # @return [Result] definitions and namespaces found
      def self.extract(source)
        tree = Prism.parse(source).value
        visitor = new
        visitor.visit(tree)
        Result.new(
          definitions: visitor.definitions.uniq,
          namespaces: visitor.namespaces.uniq
        )
      end

      attr_reader :definitions, :namespaces

      def initialize
        @definitions = []
        @namespaces  = []
        @scope_stack = []
      end

      def visit_module_node(node)
        name = resolve_constant_path(node.constant_path)
        return super unless name

        full_name = scoped_name(name)
        if namespace_only?(node)
          @namespaces << full_name
        else
          @definitions << full_name
        end

        @scope_stack.push(full_name)
        super
        @scope_stack.pop
      end

      def visit_class_node(node)
        name = resolve_constant_path(node.constant_path)
        return super unless name

        full_name = scoped_name(name)
        @definitions << full_name

        @scope_stack.push(full_name)
        super
        @scope_stack.pop
      end

      private

      def scoped_name(name)
        if name.include?("::")
          name
        elsif @scope_stack.any?
          "#{@scope_stack.last}::#{name}"
        else
          name
        end
      end

      def resolve_constant_path(node)
        case node
        when Prism::ConstantReadNode
          node.name.to_s
        when Prism::ConstantPathNode
          parts = []
          current = node
          while current.is_a?(Prism::ConstantPathNode)
            parts.unshift(current.name.to_s)
            current = current.parent
          end
          parts.unshift(current.name.to_s) if current.is_a?(Prism::ConstantReadNode)
          parts.join("::")
        end
      end

      # A module is namespace-only if its body contains only other
      # class/module nodes — no method defs, no constant assignments,
      # no include/extend calls.
      def namespace_only?(node)
        body = node.body
        return true unless body

        statements = case body
                     when Prism::StatementsNode then body.body
                     else [body]
                     end

        statements.all? { |s|
          s.is_a?(Prism::ModuleNode) ||
          s.is_a?(Prism::ClassNode)
        }
      end
    end
  end
end
