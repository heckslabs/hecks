  # Hecks::WorkflowExecutor
  #
  # Executes workflow steps in order against the runtime's command bus.
  # At branches, evaluates the named specification against the last command
  # result to choose the if_steps or else_steps path. Uses the domain module
  # to resolve specification classes.
  #
  #   executor = WorkflowExecutor.new(workflow, command_bus, domain_mod)
  #   result = executor.call(principal: 75_000)
  #
module Hecks
  class WorkflowExecutor
    CommandStep = DomainModel::Behavior::CommandStep
    BranchStep  = DomainModel::Behavior::BranchStep

    # Creates a new workflow executor.
    #
    # @param workflow [Hecks::DomainModel::Workflow] the workflow definition containing
    #   ordered steps (commands and branches)
    # @param command_bus [Hecks::CommandBus] the command bus to dispatch commands through
    # @param domain_mod [Module] the domain module used to resolve specification classes
    #   for branch evaluation
    def initialize(workflow, command_bus, domain_mod)
      @workflow = workflow
      @command_bus = command_bus
      @domain_mod = domain_mod
    end

    # Executes the workflow with the given initial attributes.
    #
    # Runs through all steps in order, passing initial attributes to each command
    # and using the result of the previous step for branch evaluation and attribute
    # mapping.
    #
    # @param initial_attrs [Hash] keyword arguments to seed the workflow execution
    # @return [Object, nil] the result of the last executed step, or nil if no steps ran
    def call(**initial_attrs)
      execute_steps(@workflow.steps, initial_attrs)
    end

    private

    # Executes an ordered list of steps, returning the result of the last step.
    #
    # Each step is either a command step (has a +:command+ key) or a branch step
    # (has a +:branch+ key). Command steps are dispatched via +dispatch_step+;
    # branch steps are evaluated via +execute_branch+.
    #
    # @param steps [Array<Hash>] the list of step definitions to execute
    # @param attrs [Hash] the initial attributes passed through the workflow
    # @return [Object, nil] the result of the last executed step
    def execute_steps(steps, attrs)
      result = nil

      steps.each do |step|
        case step
        when CommandStep
          result = dispatch_step(step, attrs, result)
        when BranchStep
          result = execute_branch(step, attrs, result)
        end
      end

      result
    end

    # Dispatches a single command step through the command bus.
    #
    # Applies any attribute mapping defined on the step before dispatching,
    # allowing values from the previous step's result to flow into the next command.
    #
    # @param step [Hash] the step definition with +:command+ and +:mapping+ keys
    # @param attrs [Hash] the initial workflow attributes
    # @param last_result [Object, nil] the result of the previous step (used for mapping)
    # @return [Object] the result of the dispatched command
    def dispatch_step(step, attrs, last_result)
      mapped = apply_mapping(step.mapping, attrs, last_result)
      @command_bus.dispatch(step.command, **mapped)
    end

    # Evaluates a branch by checking the named specification against the last result.
    #
    # If the specification class is found and +satisfied_by?+ returns true for the
    # last result, executes the +if_steps+ path. Otherwise, executes the +else_steps+ path.
    #
    # @param branch [Hash] the branch definition with +:spec+, +:if_steps+, and +:else_steps+ keys
    # @param attrs [Hash] the initial workflow attributes
    # @param last_result [Object, nil] the result to check against the specification
    # @return [Object, nil] the result of executing the chosen branch path
    def execute_branch(branch, attrs, last_result)
      spec_class = find_specification(branch.spec)

      chosen = if spec_class && spec_class.satisfied_by?(last_result)
        branch.if_steps
      else
        branch.else_steps
      end

      execute_steps(chosen, attrs)
    end

    # Finds a specification class by name across all aggregate modules in the domain.
    #
    # Searches each aggregate module's +::Specifications+ namespace for a constant
    # matching the given name. Returns the first match found, or nil if no
    # specification exists with that name.
    #
    # @param spec_name [String, Symbol] the name of the specification class to find
    # @return [Class, nil] the specification class, or nil if not found
    def find_specification(spec_name)
      @domain_mod.constants.each do |agg_const|
        agg_mod = @domain_mod.const_get(agg_const)
        next unless agg_mod.is_a?(Module)
        specs = begin; agg_mod.const_get(:Specifications); rescue NameError; next; end
        return specs.const_get(spec_name) if specs.const_defined?(spec_name)
      end
      nil
    end

    # Applies attribute mapping from the previous step's result to the current step's input.
    #
    # For each mapping entry (from -> to), attempts to read the value from +last_result+
    # (via +send+) or falls back to +initial_attrs+. The mapped value is stored under
    # the +to+ key in the returned hash.
    #
    # Returns +initial_attrs+ unchanged if mapping is empty or +last_result+ is nil.
    #
    # @param mapping [Hash{Symbol, String => Symbol, String}] a from-key to to-key mapping
    # @param initial_attrs [Hash] the original workflow input attributes
    # @param last_result [Object, nil] the result of the previous step
    # @return [Hash] the merged attributes with mapped values applied
    def apply_mapping(mapping, initial_attrs, last_result)
      return initial_attrs if mapping.empty? || last_result.nil?

      mapped = initial_attrs.dup
      mapping.each do |from, to|
        value = last_result.respond_to?(from) ? last_result.send(from) : initial_attrs[from]
        mapped[to.to_sym] = value if value
      end
      mapped
    end
  end
end
