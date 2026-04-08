module Hecks
  module Generators
    module Infrastructure
    # Hecks::Generators::Infrastructure::SagaWiringGenerator
    #
    # Generates a static module that wires saga definitions as callable
    # start_<saga_name> methods on the domain module. Replaces the
    # hand-written Hecks::Runtime::SagaSetup mixin which iterates the
    # domain IR at boot time. The generated module eliminates runtime IR
    # traversal by emitting one explicit SagaRunner block per saga.
    #
    # == Usage
    #
    #   gen = SagaWiringGenerator.new(domain, domain_module: "PizzasDomain")
    #   gen.generate
    #   # => "module Hecks\n  class Runtime\n    module Generated\n      module SagaWiring\n  ..."
    #
    class SagaWiringGenerator < Hecks::Generator

      # Initializes the generator with a domain IR and module name.
      #
      # @param domain [Hecks::BluebookModel::Structure::Domain] the domain IR
      #   providing +sagas+ to wire
      # @param domain_module [String] the PascalCase domain module name
      #   (e.g. +"PizzasDomain"+)
      def initialize(domain, domain_module:)
        @domain = domain
        @domain_module = domain_module
      end

      # Generates Ruby source for the SagaWiring module.
      #
      # Produces a module under +Hecks::Runtime::Generated+ containing a
      # private +setup_sagas+ method. For each saga defined in the domain,
      # emits a block that instantiates a SagaRunner with the saga
      # definition, command bus, saga store, and event bus, then defines
      # a +start_<underscored_saga_name>+ singleton method on the domain
      # module.
      #
      # @return [String] the complete Ruby source code, newline-terminated
      def generate
        lines = []
        lines << "module Hecks"
        lines << "  class Runtime"
        lines << "    module Generated"
        lines << "      module SagaWiring"
        lines << "        private"
        lines << ""
        lines << "        def setup_sagas"
        lines << "          return unless @domain.respond_to?(:sagas)"
        lines << "          return if @domain.sagas.empty?"
        lines << ""
        lines << "          @saga_store ||= SagaStore.new"
        lines << ""
        lines << "          mod = @mod"
        lines << "          command_bus = @command_bus"
        lines << "          event_bus = @event_bus"
        lines << "          saga_store = @saga_store"
        sagas.each_with_index do |saga, idx|
          method_name = "start_#{bluebook_snake_name(saga.name)}"
          lines << "" if idx > 0
          lines << "          saga_def = @domain.sagas.detect { |s| s.name == \"#{saga.name}\" }"
          lines << "          runner = SagaRunner.new(saga_def, command_bus, saga_store, event_bus)"
          lines << "          mod.define_singleton_method(:#{method_name}) do |**attrs|"
          lines << "            runner.start(**attrs)"
          lines << "          end"
        end
        lines << "        end"
        lines << "      end"
        lines << "    end"
        lines << "  end"
        lines << "end"
        lines.join("\n") + "\n"
      end

      private

      # Returns the sagas from the domain IR, or an empty array if none.
      #
      # @return [Array] saga definitions from the domain
      def sagas
        return [] unless @domain.respond_to?(:sagas)

        @domain.sagas
      end
    end
    end
  end
end
