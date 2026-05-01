# Hecks::Compiler::ReferenceExtractor
#
# Prism AST visitor that extracts constant references from Ruby source.
# Captures inheritance (superclass), include/extend mixins, and general
# constant path reads. Used by SourceAnalyzer to build dependency edges.
#
#   refs = ReferenceExtractor.extract(source)
#   refs  # => ["Hecks::Compiler", "Prism::Visitor", "JSON"]
#
require "prism"

module Hecks
  module Compiler
    class ReferenceExtractor < Prism::Visitor
      # Ruby stdlib constants that should never create dependency edges.
      STDLIB = %w[
        String Integer Float Numeric Symbol Array Hash Set
        Object BasicObject Kernel Module Class Struct
        Comparable Enumerable Enumerator
        IO File Dir FileUtils Pathname
        Regexp MatchData Range
        Time Date DateTime
        Proc Method UnboundMethod
        Thread Mutex Monitor
        Exception StandardError RuntimeError
        ArgumentError TypeError NameError NoMethodError
        LoadError IOError Errno SystemCallError
        NilClass TrueClass FalseClass
        Math Process Signal ENV ARGV STDIN STDOUT STDERR
        Marshal ObjectSpace GC
        JSON OpenStruct Psych YAML
        Gem Bundler
        Data
      ].to_set.freeze

      # Result struct holding constant references, mixin refs, and method calls.
      Result = Struct.new(:references, :mixin_refs, :method_calls, keyword_init: true)

      # Extracts all constant references and Hecks.method calls from source.
      #
      # @param source [String] Ruby source code
      # @return [Result] references and method_calls found
      def self.extract(source)
        tree = Prism.parse(source).value
        visitor = new
        visitor.visit(tree)
        Result.new(
          references: visitor.references.uniq,
          mixin_refs: visitor.mixin_refs.uniq,
          method_calls: visitor.method_calls.uniq
        )
      end

      attr_reader :references, :mixin_refs, :method_calls

      def initialize
        @references = []
        @mixin_refs = []
        @method_calls = []
        @scope_stack = []
      end

      def visit_class_node(node)
        name = resolve_constant_path(node.constant_path)
        @scope_stack.push(name) if name

        if node.superclass
          ref = resolve_constant_path(node.superclass)
          if ref
            record(ref)
            @mixin_refs << ref
          end
        end

        super
        @scope_stack.pop if name
      end

      def visit_module_node(node)
        name = resolve_constant_path(node.constant_path)
        @scope_stack.push(name) if name
        super
        @scope_stack.pop if name
      end

      def visit_call_node(node)
        if mixin_call?(node)
          node.arguments&.arguments&.each do |arg|
            ref = resolve_constant_path(arg)
            if ref
              record(ref)
              @mixin_refs << ref
            end
          end
        end

        # Detect Hecks.method_name calls for Bluebook IR resolution
        if hecks_method_call?(node)
          @method_calls << node.name.to_s
        end

        super
      end

      def visit_constant_path_node(node)
        ref = resolve_constant_path(node)
        record(ref) if ref
        # Don't call super — we've already walked the path
      end

      def visit_constant_read_node(node)
        record(node.name.to_s)
      end

      private

      def mixin_call?(node)
        return false unless node.receiver.nil?
        %i[include extend prepend].include?(node.name)
      end

      # Detects calls like Hecks.describe_extension, Hecks.register_xxx
      def hecks_method_call?(node)
        return false unless node.receiver
        receiver_name = resolve_constant_path(node.receiver)
        receiver_name == "Hecks" && node.name.to_s != "new"
      end

      def record(name)
        root = name.split("::").first
        return if STDLIB.include?(root)
        return if STDLIB.include?(name)
        @references << name
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
          if current.is_a?(Prism::ConstantReadNode)
            parts.unshift(current.name.to_s)
          end
          parts.join("::")
        end
      end
    end
  end
end
