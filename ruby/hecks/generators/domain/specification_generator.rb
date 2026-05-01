module Hecks
  module Generators
    module Domain
    # Hecks::Generators::Domain::SpecificationGenerator
    #
    # Generates specification classes nested under Aggregate::Specifications.
    # Implements the Specification pattern -- each specification has a
    # +satisfied_by?+ method that tests whether a domain object meets certain
    # criteria. The method's parameters and body are extracted from the DSL block.
    #
    # If the DSL block has no explicit parameters, the method receives a single
    # +object+ parameter by default.
    #
    # The Hecks::Specification mixin is injected at load time by InMemoryLoader
    # or by const_missing (file-based gems), providing composability (+and+, +or+,
    # +not+ combinators).
    #
    # Part of Generators::Domain, consumed by DomainGemGenerator and InMemoryLoader.
    #
    # == Usage
    #
    #   gen = SpecificationGenerator.new(spec, domain_module: "BankingDomain", aggregate_name: "Loan")
    #   gen.generate
    #
    class SpecificationGenerator

      # Initializes the specification generator.
      #
      # @param specification [Object] the specification model object; provides +name+ and +block+
      # @param domain_module [String] the Ruby module name to wrap the generated class in
      # @param aggregate_name [String] the name of the parent aggregate class
      def initialize(specification, domain_module:, aggregate_name:, mixin_prefix: "Hecks")
        @specification = specification
        @domain_module = domain_module
        @aggregate_name = aggregate_name
        @mixin_prefix = mixin_prefix
      end

      # Generates the full Ruby source code for the specification class.
      #
      # Produces a class nested under +Aggregate::Specifications+ with a
      # +satisfied_by?+ method whose parameters and body come from the DSL block.
      #
      # @return [String] the generated Ruby source code, newline-terminated
      def generate
        lines = []
        lines << "module #{@domain_module}"
        lines << "  class #{@aggregate_name}"
        lines << "    module Specifications"
        lines << "      class #{@specification.name}"
        lines << "        def satisfied_by?#{call_params}"
        lines << "          #{call_body}"
        lines << "        end"
        lines << "      end"
        lines << "    end"
        lines << "  end"
        lines << "end"
        lines.join("\n") + "\n"
      end

      private

      # Formats the parameter list for the +satisfied_by?+ method.
      #
      # If the DSL block has explicit parameters, those are used. Otherwise
      # defaults to +(object)+ as the single parameter.
      #
      # @return [String] formatted parameter list (e.g., "(object)" or "(loan, threshold)")
      def call_params
        params = block_params
        return "(object)" if params.empty?
        "(#{params.join(", ")})"
      end

      # Extracts parameter names from the specification's DSL block.
      #
      # @return [Array<String>] parameter name strings
      def block_params
        @specification.block.parameters.map { |_, name| name.to_s }
      end

      # Extracts the source code from the specification's DSL block.
      #
      # @return [String] the block's source code as a string
      def call_body
        Hecks::Utils.block_source(@specification.block)
      end
    end
    end
  end
end
