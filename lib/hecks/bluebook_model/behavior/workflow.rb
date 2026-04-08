module Hecks
  module BluebookModel
    module Behavior

      # Hecks::BluebookModel::Behavior::Workflow
      #
      # Intermediate representation of a workflow -- a conditional multi-step
      # command orchestration. Each workflow has a name and an ordered array of
      # steps. Steps are either sequential commands (with optional attribute
      # mapping) or branches that evaluate a specification to choose a path.
      #
      # Workflows can also be scheduled (recurring or one-time) via the +schedule+
      # attribute, which holds a cron-like string or scheduling descriptor.
      #
      # == Step formats
      #
      # Steps are plain hashes in one of two forms:
      #
      # 1. Command step: <tt>{ command: "DoSomething", mapping: { from: :to } }</tt>
      #    Dispatches the named command with optional attribute remapping.
      #
      # 2. Branch step: <tt>{ branch: { spec: "SpecName", if_steps: [...], else_steps: [...] } }</tt>
      #    Evaluates the named specification; if truthy, runs +if_steps+; otherwise runs +else_steps+.
      #    Each sub-step follows the same format recursively.
      #
      # Part of the BluebookModel IR layer. Built by WorkflowBuilder in the DSL,
      # consumed by WorkflowRunner at runtime to execute the step sequence.
      #
      #   workflow = Workflow.new(
      #     name: "LoanApproval",
      #     steps: [
      #       { command: "ScoreLoan", mapping: {} },
      #       { branch: { spec: "HighRisk", if_steps: [...], else_steps: [...] } }
      #     ]
      #   )
      #   workflow.scheduled?  # => false
      #
      class Workflow
        # @return [String] PascalCase workflow name (e.g. "LoanApproval")
        # @return [Array<Hash>] ordered list of step hashes. Each is either a
        #   command step ({ command: String, mapping: Hash }) or a branch step
        #   ({ branch: { spec: String, if_steps: Array, else_steps: Array } })
        # @return [String, nil] schedule descriptor (e.g. a cron expression) for
        #   recurring workflows, or nil for on-demand workflows
        attr_reader :name, :steps, :schedule, :description

        # Creates a new Workflow IR node.
        #
        # @param name [String] PascalCase workflow name (e.g. "LoanApproval")
        # @param steps [Array<Hash>] ordered step definitions. Each hash is either:
        #   - A command step: <tt>{ command: "CommandName", mapping: { source: :target } }</tt>
        #   - A branch step: <tt>{ branch: { spec: "SpecName", if_steps: [...], else_steps: [...] } }</tt>
        #   Defaults to an empty array.
        # @param schedule [String, nil] a cron expression or scheduling descriptor
        #   for recurring execution. Nil means the workflow runs on-demand only.
        # @return [Workflow]
        def initialize(name:, steps: [], schedule: nil, description: nil)
          @name = name
          @steps = steps
          @schedule = schedule
          @description = description
        end

        # Returns whether this workflow is scheduled for recurring or timed execution.
        #
        # @return [Boolean] true if a schedule has been defined, false for on-demand workflows
        def scheduled?
          !@schedule.nil?
        end
      end
    end
  end
end
