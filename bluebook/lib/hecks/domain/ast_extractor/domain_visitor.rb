# Hecks::AstExtractor::DomainVisitor
#
# Walks the top-level domain ITER node, extracting the domain name and all
# domain-level declarations: aggregates, policies, services, views,
# workflows, and world goals. Delegates aggregate extraction to
# AggregateVisitor.
#
#   visitor = DomainVisitor.new(iter_node)
#   visitor.visit  # => { name: "Pizzas", aggregates: [...], policies: [...], ... }
#
module Hecks
  class AstExtractor
    class DomainVisitor
      include NodeReaders

      def initialize(node)
        @node = node
      end

      def visit
        name = extract_domain_name
        scope = @node.children[1]
        stmts = block_statements(scope)

        result = new_domain(name)
        stmts.each { |stmt| visit_statement(stmt, result) }
        result
      end

      private

      def extract_domain_name
        call_node = @node.children[0]
        args_node = call_node.children[2]
        read_args(args_node).first
      end

      def new_domain(name)
        { name: name, aggregates: [], policies: [], services: [],
          views: [], workflows: [], world_goals: [], actors: [],
          sagas: [], glossary_rules: [], modules: [] }
      end

      def visit_statement(stmt, domain)
        method = call_method_name(stmt)
        case method
        when :aggregate    then domain[:aggregates] << AggregateVisitor.new(stmt).visit
        when :policy       then domain[:policies] << extract_domain_policy(stmt)
        when :service      then domain[:services] << extract_service(stmt)
        when :view         then domain[:views] << extract_view(stmt)
        when :workflow     then domain[:workflows] << extract_workflow(stmt)
        when :world_goals  then extract_world_goals(stmt, domain)
        when :actor        then domain[:actors] << extract_actor(stmt)
        when :saga         then domain[:sagas] << extract_saga(stmt)
        when :domain_module then domain[:modules] << extract_module(stmt)
        else
          visit_implicit_aggregate(stmt, domain) if implicit_aggregate?(stmt)
        end
      end

      def extract_domain_policy(stmt)
        scope = stmt.children[1]
        stmts = block_statements(scope)
        pol = { name: call_args(stmt).first, event_name: nil,
                trigger_command: nil, async: false, attribute_map: {} }
        stmts.each do |s|
          m = call_method_name(s)
          case m
          when :on      then pol[:event_name] = call_args(s).first
          when :trigger then pol[:trigger_command] = call_args(s).first
          when :async   then pol[:async] = true
          when :map     then pol[:attribute_map] = call_kwargs(s)
          end
        end
        pol
      end

      def extract_service(stmt)
        name = call_args(stmt).first
        scope = stmt.children[1]
        stmts = block_statements(scope)
        svc = { name: name, attributes: [], coordinates: [] }
        stmts.each do |s|
          m = call_method_name(s)
          case m
          when :attribute   then svc[:attributes] << extract_attribute_hash(s)
          when :coordinates then svc[:coordinates] = call_args(s).map(&:to_s)
          end
        end
        svc
      end

      def extract_view(stmt)
        { name: call_args(stmt).first }
      end

      def extract_workflow(stmt)
        { name: call_args(stmt).first }
      end

      def extract_world_goals(stmt, domain)
        args = call_args(stmt)
        domain[:world_goals].concat(args.map { |a| a.is_a?(Symbol) ? a : a.to_sym })
      end

      def extract_actor(stmt)
        { name: call_args(stmt).first.to_s }
      end

      def extract_saga(stmt)
        { name: call_args(stmt).first }
      end

      def extract_module(stmt)
        { name: call_args(stmt).first }
      end

      def extract_attribute_hash(node)
        args = call_args(node)
        { name: args[0], type: (args[1] || "String").to_s }
      end

      def implicit_aggregate?(stmt)
        return false unless stmt.is_a?(RubyVM::AbstractSyntaxTree::Node)
        return false unless stmt.type == :ITER
        fcall = stmt.children[0]
        return false unless fcall&.type == :FCALL
        name = fcall.children[0].to_s
        name.match?(/\A[A-Z]/)
      end

      def visit_implicit_aggregate(stmt, domain)
        domain[:aggregates] << AggregateVisitor.new(stmt).visit
      end
    end
  end
end
