module Hecks
  module Generators
    module Infrastructure
    # Hecks::Generators::Infrastructure::RepositoryWiringGenerator
    #
    # Generates a static module that wires up default memory repositories
    # for every aggregate in the domain. Replaces the hand-written
    # Hecks::Runtime::RepositorySetup mixin which iterates the domain IR
    # at boot time. The generated module eliminates runtime IR traversal
    # by emitting one explicit block per aggregate.
    #
    # == Usage
    #
    #   gen = RepositoryWiringGenerator.new(domain, domain_module: "PizzasDomain")
    #   gen.generate
    #   # => "module Hecks\n  class Runtime\n    module Generated\n      module RepositoryWiring\n  ..."
    #
    class RepositoryWiringGenerator < Hecks::Generator

      # Initializes the generator with a domain IR and module name.
      #
      # @param domain [Hecks::DomainModel::Structure::Domain] the domain IR
      #   providing +aggregates+ to wire
      # @param domain_module [String] the PascalCase domain module name
      #   (e.g. +"PizzasDomain"+)
      def initialize(domain, domain_module:)
        @domain = domain
        @domain_module = domain_module
      end

      # Generates Ruby source for the RepositoryWiring module.
      #
      # Produces a module under +Hecks::Runtime::Generated+ containing a
      # private +setup_repositories+ method. Each aggregate gets an explicit
      # +unless @adapter_overrides.key?+ block that instantiates its default
      # memory repository. A final loop applies any remaining overrides.
      #
      # @return [String] the complete Ruby source code, newline-terminated
      def generate
        lines = []
        lines << "module Hecks"
        lines << "  class Runtime"
        lines << "    module Generated"
        lines << "      module RepositoryWiring"
        lines << "        private"
        lines << ""
        lines << "        def setup_repositories"
        @domain.aggregates.each_with_index do |agg, idx|
          name = domain_constant_name(agg.name)
          lines << "" if idx > 0
          lines << "          unless @adapter_overrides.key?(\"#{name}\")"
          lines << "            @repositories[\"#{name}\"] = @mod::Adapters::#{name}MemoryRepository.new"
          lines << "          end"
        end
        lines << "          @adapter_overrides.each do |name, adapter|"
        lines << "            @repositories[name] = adapter unless @repositories.key?(name)"
        lines << "          end"
        lines << "        end"
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
