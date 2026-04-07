module Hecks
  module Generators
    module Domain
    # Hecks::Generators::Domain::QueryGenerator
    #
    # Generates query classes nested under Aggregate::Queries. Extracts the
    # DSL block source and emits it as the body of a +call+ method. The
    # Hecks::Query mixin is injected at load time by InMemoryLoader or by
    # const_missing (file-based gems). Part of Generators::Domain,
    # consumed by DomainGemGenerator and InMemoryLoader.
    #
    # Query classes encapsulate read-side logic that operates on the repository.
    # The block's parameters become the +call+ method's parameters, and its
    # source becomes the method body.
    #
    # == Usage
    #
    #   gen = QueryGenerator.new(query, domain_module: "PizzasDomain", aggregate_name: "Pizza")
    #   gen.generate
    #
    class QueryGenerator

      # Initializes the query generator.
      #
      # @param query [Object] the query model object; provides +name+ and +block+
      # @param domain_module [String] the Ruby module name to wrap the generated class in
      # @param aggregate_name [String] the name of the parent aggregate class
      def initialize(query, domain_module:, aggregate_name:, mixin_prefix: "Hecks")
        @query = query
        @domain_module = domain_module
        @aggregate_name = aggregate_name
        @mixin_prefix = mixin_prefix
      end

      # Generates the full Ruby source code for the query class.
      #
      # Produces a class nested under +Aggregate::Queries+ with a +call+ method
      # whose parameters and body come from the DSL block.
      #
      # @return [String] the generated Ruby source code, newline-terminated
      def generate
        lines = []
        lines << "module #{@domain_module}"
        lines << "  class #{@aggregate_name}"
        lines << "    module Queries"
        lines << "      class #{Hecks::Utils.sanitize_constant(@query.name.to_s)}"
        lines << "        def call#{call_params}"
        lines << "          #{call_body}"
        lines << "        end"
        lines << "      end"
        lines << "    end"
        lines << "  end"
        lines << "end"
        lines.join("\n") + "\n"
      end

      private

      # Formats the parameter list for the +call+ method.
      #
      # @return [String] formatted parameter list (e.g., "(name, size)") or empty string
      #   if the block takes no parameters
      def call_params
        params = block_params
        return "" if params.empty?
        "(#{params.join(", ")})"
      end

      # Extracts parameter names from the query's DSL block.
      #
      # @return [Array<String>] parameter name strings
      def block_params
        @query.block.parameters.map { |_, name| name.to_s }
      end

      # Extracts the source code from the query's DSL block.
      #
      # @return [String] the block's source code as a string
      def call_body
        Hecks::Utils.block_source(@query.block)
      end
    end
    end
  end
end
