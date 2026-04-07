# Hecks::Generators::Infrastructure::WorkflowWiringGenerator
#
# Generates a static module that wires workflow executors as callable
# singleton methods on the domain module. Replaces the hand-written
# Hecks::Runtime::WorkflowSetup mixin which iterates the domain IR
# at boot time. The generated module emits one explicit method
# definition per workflow, eliminating runtime IR traversal.
#
# == Usage
#
#   gen = WorkflowWiringGenerator.new(domain, domain_module: "PizzasDomain")
#   gen.generate
#   # => "module Hecks\n  class Runtime\n    module Generated\n      module WorkflowWiring\n  ..."
#

module Hecks
  module Generators
    module Infrastructure
    class WorkflowWiringGenerator < Hecks::Generator

      # Initializes the generator with a domain IR and module name.
      #
      # @param domain [Hecks::DomainModel::Structure::Domain] the domain IR
      #   providing +workflows+ to wire
      # @param domain_module [String] the PascalCase domain module name
      #   (e.g. +"PizzasDomain"+)
      def initialize(domain, domain_module:)
        @domain = domain
        @domain_module = domain_module
      end

      # Generates Ruby source for the WorkflowWiring module.
      #
      # Produces a module under +Hecks::Runtime::Generated+ containing a
      # private +setup_workflows+ method. Each workflow gets a
      # +WorkflowExecutor+ instantiation and a +define_singleton_method+
      # call that exposes the workflow as a keyword-argument method on the
      # domain module.
      #
      # Returns an empty +setup_workflows+ if the domain has no workflows.
      #
      # @return [String] the complete Ruby source code, newline-terminated
      def generate
        lines = []
        lines << "module Hecks"
        lines << "  class Runtime"
        lines << "    module Generated"
        lines << "      module WorkflowWiring"
        lines << "        private"
        lines << ""
        lines << "        def setup_workflows"
        workflows = @domain.respond_to?(:workflows) ? (@domain.workflows || []) : []
        workflows.each_with_index do |workflow, idx|
          method_name = domain_snake_name(workflow.name)
          lines << "" if idx > 0
          lines << "          executor = WorkflowExecutor.new("
          lines << "            @domain.workflows.find { |w| w.name == \"#{workflow.name}\" },"
          lines << "            @command_bus,"
          lines << "            @mod"
          lines << "          )"
          lines << "          @mod.define_singleton_method(:#{method_name}) do |**attrs|"
          lines << "            executor.call(**attrs)"
          lines << "          end"
        end
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
