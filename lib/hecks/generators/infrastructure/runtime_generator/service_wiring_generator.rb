module Hecks
  module Generators
    module Infrastructure
    # Hecks::Generators::Infrastructure::ServiceWiringGenerator
    #
    # Generates a static module that wires domain services as callable
    # singleton methods on the domain module. Replaces the hand-written
    # Hecks::ServiceSetup mixin which iterates the domain IR at boot time.
    # Each service becomes an explicit method definition that builds a
    # ServiceContext, evaluates the call body, and returns results.
    #
    # == Usage
    #
    #   gen = ServiceWiringGenerator.new(domain, domain_module: "BankingDomain")
    #   gen.generate
    #   # => "module Hecks\n  class Runtime\n    module Generated\n      module ServiceWiring\n  ..."
    #
    class ServiceWiringGenerator < Hecks::Generator

      # Initializes the generator with a domain IR and module name.
      #
      # @param domain [Hecks::BluebookModel::Structure::Domain] the domain IR
      #   providing +services+ to wire
      # @param domain_module [String] the PascalCase domain module name
      #   (e.g. +"BankingDomain"+)
      def initialize(domain, domain_module:)
        @domain = domain
        @domain_module = domain_module
      end

      # Generates Ruby source for the ServiceWiring module.
      #
      # Produces a module under +Hecks::Runtime::Generated+ containing a
      # private +setup_services+ method. For each domain service, it emits
      # a +define_singleton_method+ call that creates a ServiceContext with
      # the command bus, evaluates the service call body, and returns the
      # accumulated results.
      #
      # @return [String] the complete Ruby source code, newline-terminated
      def generate
        lines = []
        lines << "module Hecks"
        lines << "  class Runtime"
        lines << "    module Generated"
        lines << "      module ServiceWiring"
        lines << "        private"
        lines << ""
        lines << "        def setup_services"
        lines << "          mod = @mod"
        lines << "          command_bus = @command_bus"
        services.each_with_index do |svc, idx|
          lines << "" if idx > 0
          lines.concat(service_lines(svc))
        end
        lines << "        end"
        lines << "      end"
        lines << "    end"
        lines << "  end"
        lines << "end"
        lines.join("\n") + "\n"
      end

      private

      # Returns the list of services from the domain IR.
      #
      # @return [Array<Hecks::BluebookModel::Behavior::Service>] domain services
      def services
        @domain.services || []
      end

      # Generates the lines for a single service method definition.
      #
      # Emits a +define_singleton_method+ block on the domain module that:
      # 1. Builds a ServiceContext with the command bus, attribute names, and kwargs
      # 2. Evaluates the service call body within that context
      # 3. Returns +ctx.results+ with all dispatched command results
      #
      # @param svc [Hecks::BluebookModel::Behavior::Service] the service to wire
      # @return [Array<String>] indented lines of Ruby source
      def service_lines(svc)
        method_name = bluebook_snake_name(svc.name)
        attr_names = svc.attributes.map { |a| a.name.to_s.inspect }
        call_body_source = svc.call_body ? Hecks::Utils.block_source(svc.call_body) : nil

        lines = []
        lines << "          mod.define_singleton_method(:#{method_name}) do |**kwargs|"
        lines << "            attr_names = [#{attr_names.join(', ')}]"
        lines << "            ctx = Hecks::ServiceContext.new(command_bus, attr_names, kwargs)"
        if call_body_source
          lines << "            ctx.instance_eval do"
          lines << "              #{call_body_source}"
          lines << "            end"
        end
        lines << "            ctx.results"
        lines << "          end"
        lines
      end
    end
    end
  end
end
