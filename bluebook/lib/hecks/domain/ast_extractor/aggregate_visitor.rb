# Hecks::AstExtractor::AggregateVisitor
#
# Walks an AST node for an aggregate block, extracting attributes, commands,
# value objects, entities, policies, validations, specifications, references,
# and queries. Each DSL method maps to a specific extraction method.
#
#   visitor = AggregateVisitor.new(iter_node)
#   visitor.visit  # => { name: "Pizza", attributes: [...], commands: [...], ... }
#
module Hecks
  class AstExtractor
    class AggregateVisitor
      include NodeReaders

      def initialize(node)
        @node = node
      end

      def visit
        name = call_args(@node).first
        scope = @node.children[1]
        stmts = block_statements(scope)

        result = new_aggregate(name)
        stmts.each { |stmt| visit_statement(stmt, result) }
        result
      end

      private

      def new_aggregate(name)
        { name: name, attributes: [], value_objects: [], entities: [],
          commands: [], policies: [], validations: [], specifications: [],
          references: [], queries: [], invariants: [], scopes: [],
          subscribers: [], indexes: [] }
      end

      def visit_statement(stmt, agg)
        method = call_method_name(stmt)
        case method
        when :attribute    then agg[:attributes] << extract_attribute(stmt)
        when :value_object then agg[:value_objects] << extract_nested_type(stmt, :value_object)
        when :entity       then agg[:entities] << extract_nested_type(stmt, :entity)
        when :command      then agg[:commands] << extract_command(stmt)
        when :policy       then agg[:policies] << extract_policy(stmt)
        when :validation   then agg[:validations] << extract_validation(stmt)
        when :specification then agg[:specifications] << extract_specification(stmt)
        when :reference_to then agg[:references] << extract_reference(stmt)
        when :query        then agg[:queries] << extract_query(stmt)
        when :event        then nil # explicit events handled by domain builder
        when :scope        then agg[:scopes] << extract_scope(stmt)
        end
      end

      def extract_attribute(node)
        args = call_args(node)
        kwargs = call_kwargs(node)
        name = args[0]
        type_arg = args[1]
        type_info = resolve_type(type_arg)
        { name: name, type: type_info[:type], list: type_info[:list],
          default: kwargs[:default] }.compact
      end

      def resolve_type(type_arg)
        case type_arg
        when Hash then { type: type_arg[:list], list: true }
        when String
          if %w[String Integer Float Date DateTime].include?(type_arg)
            { type: type_arg, list: false }
          else
            { type: type_arg, list: false }
          end
        when nil then { type: "String", list: false }
        else { type: type_arg.to_s, list: false }
        end
      end

      def extract_nested_type(node, kind)
        name = call_args(node).first
        scope = node.children[1]
        stmts = block_statements(scope)
        result = { name: name, attributes: [], invariants: [] }
        stmts.each do |stmt|
          m = call_method_name(stmt)
          case m
          when :attribute then result[:attributes] << extract_attribute(stmt)
          when :invariant then result[:invariants] << extract_invariant(stmt)
          end
        end
        result
      end

      def extract_command(node)
        name = call_args(node).first
        scope = node.children[1]
        stmts = block_statements(scope)
        cmd = { name: name, attributes: [], references: [] }
        stmts.each do |stmt|
          m = call_method_name(stmt)
          case m
          when :attribute    then cmd[:attributes] << extract_attribute(stmt)
          when :reference_to then cmd[:references] << extract_reference(stmt)
          end
        end
        cmd
      end

      def extract_policy(node)
        name = call_args(node).first
        scope = node.children[1]
        stmts = block_statements(scope)
        pol = { name: name, event_name: nil, trigger_command: nil, async: false }
        stmts.each do |stmt|
          m = call_method_name(stmt)
          case m
          when :on      then pol[:event_name] = call_args(stmt).first
          when :trigger then pol[:trigger_command] = call_args(stmt).first
          when :async   then pol[:async] = true
          end
        end
        pol
      end

      def extract_validation(node)
        args = call_args(node)
        kwargs = call_kwargs(node)
        { field: args.first, rules: kwargs }
      end

      def extract_specification(node)
        { name: call_args(node).first }
      end

      def extract_reference(node)
        args = call_args(node)
        kwargs = call_kwargs(node)
        type_str = args.first.to_s
        parts = type_str.split("::")
        target = parts.last
        domain = parts.length > 1 ? parts[0..-2].join("::") : nil
        { type: target, domain: domain, role: kwargs[:role],
          validate: kwargs.fetch(:validate, true) }
      end

      def extract_query(node)
        { name: call_args(node).first }
      end

      def extract_invariant(node)
        { message: call_args(node).first }
      end

      def extract_scope(node)
        args = call_args(node)
        kwargs = call_kwargs(node)
        { name: args.first, conditions: kwargs }
      end
    end
  end
end
