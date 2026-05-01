module Hecks
  module DSL

    # Hecks::DSL::WorkflowBuilder
    #
    # DSL builder for workflow definitions. Collects sequential steps and
    # conditional branches, then builds a BluebookModel::Behavior::Workflow.
    #
    #   builder = WorkflowBuilder.new("LoanApproval")
    #   builder.step "ScoreLoan", score: :principal
    #   builder.branch do
    #     when_spec("HighRisk") { step "ReviewLoan" }
    #     otherwise { step "ApproveLoan" }
    #   end
    #   workflow = builder.build
    #
    # Builds a BluebookModel::Behavior::Workflow from step and branch declarations.
    #
    # WorkflowBuilder defines multi-step orchestrations that compose commands
    # with conditional branching. Steps execute commands with optional field
    # mapping, while branches use specification predicates to choose between
    # alternative step sequences. Workflows can also be scheduled to run on
    # a recurring interval.
    #
    # Used inside +BluebookBuilder#workflow+ blocks.
    class WorkflowBuilder
      Behavior = BluebookModel::Behavior

      include Describable

      # Initialize a new workflow builder with the given workflow name.
      #
      # @param name [String] the workflow name (e.g. "LoanApproval")
      def initialize(name)
        @name = name
        @steps = []
        @schedule = nil
      end

      # Set a recurring schedule interval for this workflow.
      #
      # Scheduled workflows run automatically at the given interval.
      # The runtime interprets the interval format.
      #
      # @param interval [String, Symbol] the schedule interval (e.g. "daily", "1h")
      # @return [void]
      def schedule(interval)
        @schedule = interval
      end

      # Add a workflow step that triggers a command with optional field mapping.
      #
      # When called without a block, creates a simple step that dispatches the
      # named command with field mappings. When called with a block, creates a
      # scheduled step using ScheduledStepBuilder (which can find aggregates
      # and trigger commands on them).
      #
      # @param command_name [String, nil] the command to dispatch (nil when using block form)
      # @param mapping [Hash{Symbol => Symbol}] maps source fields to command attributes
      # @yield optional block evaluated in the context of ScheduledStepBuilder
      # @return [void]
      #
      # @example Simple step
      #   step "ScoreLoan", score: :principal
      #
      # @example Scheduled step with block
      #   step "ProcessOverdue" do
      #     find "Loan", spec: :overdue
      #     trigger "MarkDelinquent"
      #   end
      def step(command_name = nil, **mapping, &block)
        if block
          step_builder = ScheduledStepBuilder.new(command_name)
          step_builder.instance_eval(&block)
          @steps << step_builder.build
        else
          @steps << Behavior::CommandStep.new(command: command_name.to_s, mapping: mapping)
        end
      end

      # Add a conditional branch point using specification predicates.
      #
      # Branches allow workflows to take different paths based on the result
      # of a specification check. The block is evaluated in the context of a
      # BranchBuilder, which provides +when_spec+ and +otherwise+ methods.
      #
      # @yield block evaluated in the context of BranchBuilder
      # @return [void]
      #
      # @example
      #   branch do
      #     when_spec("HighRisk") { step "ReviewLoan" }
      #     otherwise { step "ApproveLoan" }
      #   end
      def branch(&block)
        branch_builder = BranchBuilder.new
        branch_builder.instance_eval(&block)
        branch_data = branch_builder.build
        @steps << Behavior::BranchStep.new(**branch_data)
      end

      # Build and return the BluebookModel::Behavior::Workflow IR object.
      #
      # @return [BluebookModel::Behavior::Workflow] the fully built workflow IR object
      def build
        Behavior::Workflow.new(name: @name, steps: @steps, schedule: @schedule, description: @description)
      end
    end

    # Builds a scheduled workflow step that finds aggregates and triggers commands.
    #
    # ScheduledStepBuilder defines a step that queries for aggregates matching
    # certain criteria (via specification or query) and then triggers a command
    # on each matched aggregate. Used inside +WorkflowBuilder#step+ blocks.
    class ScheduledStepBuilder
      Behavior = BluebookModel::Behavior

      # Initialize with an optional step name.
      #
      # @param name [String, nil] an optional descriptive name for the step
      def initialize(name)
        @name = name
        @find_aggregate = nil
        @find_spec = nil
        @find_query = nil
        @trigger_command = nil
      end

      # Specify the aggregate to find, optionally filtered by spec or query.
      #
      # @param aggregate_name [String] the aggregate type to search for
      # @param spec [String, nil] optional specification name to filter by
      # @param query [String, nil] optional query name to filter by
      # @return [void]
      def find(aggregate_name, spec: nil, query: nil)
        @find_aggregate = aggregate_name
        @find_spec = spec
        @find_query = query
      end

      # Set the command to trigger on each matched aggregate.
      #
      # @param command_name [String] the command to dispatch
      # @return [void]
      def trigger(command_name)
        @trigger_command = command_name
      end

      # Build and return the step hash.
      #
      # @return [Hash] a hash with :name, :find_aggregate, :find_spec,
      #   :find_query, and :trigger keys
      def build
        Behavior::ScheduledStep.new(
          name: @name, find_aggregate: @find_aggregate, find_spec: @find_spec,
          find_query: @find_query, trigger: @trigger_command
        )
      end
    end

    # Builds conditional branches based on specification predicates.
    #
    # BranchBuilder defines an if/else fork in a workflow. The +when_spec+
    # method names a specification predicate and collects the steps to run
    # when it matches. The +otherwise+ method collects the fallback steps.
    # Used inside +WorkflowBuilder#branch+ blocks.
    class BranchBuilder
      # Initialize an empty branch with no spec or steps.
      def initialize
        @spec = nil
        @if_steps = []
        @else_steps = []
      end

      # Define the if-branch: steps to run when the spec matches.
      #
      # @param spec_name [String] the specification predicate name to evaluate
      # @yield block evaluated in the context of StepCollector to define steps
      # @return [void]
      def when_spec(spec_name, &block)
        @spec = spec_name
        collector = StepCollector.new
        collector.instance_eval(&block)
        @if_steps = collector.steps
      end

      # Define the else-branch: steps to run when the spec does not match.
      #
      # @yield block evaluated in the context of StepCollector to define steps
      # @return [void]
      def otherwise(&block)
        collector = StepCollector.new
        collector.instance_eval(&block)
        @else_steps = collector.steps
      end

      # Build and return the branch hash.
      #
      # @return [Hash] a hash with :spec, :if_steps, and :else_steps keys
      def build
        { spec: @spec, if_steps: @if_steps, else_steps: @else_steps }
      end
    end

    # Collects steps within a branch block.
    #
    # StepCollector is a minimal DSL context used inside +BranchBuilder#when_spec+
    # and +BranchBuilder#otherwise+ blocks. It provides a single +step+ method
    # to accumulate command dispatch instructions.
    class StepCollector
      Behavior = BluebookModel::Behavior

      # @return [Array<Hash>] collected step definitions, each with :command and :mapping keys
      attr_reader :steps

      # Initialize with an empty step list.
      def initialize
        @steps = []
      end

      # Add a step that triggers the named command with optional field mapping.
      #
      # @param command_name [String] the command to dispatch
      # @param mapping [Hash{Symbol => Symbol}] maps source fields to command attributes
      # @return [void]
      def step(command_name, **mapping)
        @steps << Behavior::CommandStep.new(command: command_name.to_s, mapping: mapping)
      end
    end
  end
end
