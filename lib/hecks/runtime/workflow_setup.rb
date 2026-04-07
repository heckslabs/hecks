module Hecks
  class Runtime
    # Hecks::Runtime::WorkflowSetup
    #
    # Mixin that binds workflow executors as callable methods on the domain
    # module at boot time. Each workflow becomes a method that accepts keyword
    # arguments and executes the workflow steps through the command bus.
    #
    #   class Runtime
    #     include WorkflowSetup
    #   end
    #
    module WorkflowSetup
      include HecksTemplating::NamingHelpers
      private

      # Wires all workflows defined in the domain DSL as callable singleton
      # methods on the domain module.
      #
      # For each workflow, creates a +WorkflowExecutor+ and defines a method
      # named after the underscored workflow name (e.g., workflow "ProcessLoan"
      # becomes +domain_mod.process_loan(**attrs)+).
      #
      # Returns immediately if the domain does not respond to +workflows+
      # (backward compatibility with older domain definitions).
      #
      # @return [void]
      def setup_workflows
        return unless @domain.respond_to?(:workflows)

        @domain.workflows.each do |workflow|
          executor = WorkflowExecutor.new(workflow, @command_bus, @mod)
          method_name = domain_snake_name(workflow.name).to_sym

          @mod.define_singleton_method(method_name) do |**attrs|
            executor.call(**attrs)
          end
        end
      end
    end
  end
end
