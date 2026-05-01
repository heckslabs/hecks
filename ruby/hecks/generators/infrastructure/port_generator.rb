module Hecks
  module Generators
    module Infrastructure
    # Hecks::Generators::Infrastructure::PortGenerator
    #
    # Generates repository port interfaces (modules with NotImplementedError stubs).
    # Consuming apps include the port and implement the methods. Part of
    # Generators::Infrastructure, consumed by DomainGemGenerator and InMemoryLoader.
    #
    #   gen = PortGenerator.new(agg, domain_module: "PizzasDomain")
    #   gen.generate  # => "module PizzasDomain\n  module Ports\n    module PizzaRepository\n  ..."
    #
    class PortGenerator < Hecks::Generator

      # Creates a new PortGenerator for a single aggregate.
      #
      # @param aggregate [Hecks::BluebookModel::Structure::Aggregate] the aggregate
      #   that needs a repository port interface
      # @param domain_module [String] the PascalCase domain module name
      #   (e.g. +"PizzasDomain"+)
      def initialize(aggregate, domain_module:)
        @aggregate = aggregate
        @domain_module = domain_module
        @safe_name = bluebook_constant_name(@aggregate.name)
      end

      # Generates Ruby source for a repository port module.
      #
      # The generated module defines abstract interface methods that raise
      # +NotImplementedError+ when called directly:
      # - +find(id)+ -- retrieve an aggregate by its ID
      # - +save(<snake_name>)+ -- persist an aggregate instance
      # - +delete(id)+ -- remove an aggregate by its ID
      #
      # Concrete adapters (e.g. +MemoryAdapterGenerator+ output) include this
      # module and implement the methods.
      #
      # @return [String] the complete Ruby source code for the port module
      def generate
        snake = bluebook_snake_name(@safe_name)
        lines = []
        lines << "module #{@domain_module}"
        lines << "  module Ports"
        lines << "    module #{@safe_name}Repository"
        lines << "      def find(id)"
        lines << "        raise NotImplementedError, \"\#{self.class}#find not implemented\""
        lines << "      end"
        lines << ""
        lines << "      def save(#{snake})"
        lines << "        raise NotImplementedError, \"\#{self.class}#save not implemented\""
        lines << "      end"
        lines << ""
        lines << "      def delete(id)"
        lines << "        raise NotImplementedError, \"\#{self.class}#delete not implemented\""
        lines << "      end"
        lines << "    end"
        lines << "  end"
        lines << "end"
        lines.join("\n") + "\n"
      end

    end
    end
  end
end
