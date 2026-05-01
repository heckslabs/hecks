module Hecks
  module Generators
    module Domain
    # Hecks::Generators::Domain::WorkflowGenerator
    #
    # Generates workflow classes that orchestrate multi-step domain processes
    # with conditional branching. Workflows are namespaced under +Domain::Workflows+.
    #
    # Each workflow class includes:
    # - A +STEPS+ constant -- an array of step hashes, where each step is either
    #   a command reference (+{ command: "CommandName" }+) or a branch with
    #   specification-based conditions (+{ branch: { spec: ..., when_satisfied: ..., otherwise: ... } }+)
    # - A +call(**attrs)+ method that executes steps in sequence, evaluates branches,
    #   and collects results
    #
    # Branching supports specification-based routing: if a specification is satisfied,
    # one set of commands runs; otherwise, an alternate set runs.
    #
    # Part of Generators::Domain.
    #
    # == Usage
    #
    #   gen = WorkflowGenerator.new(workflow, domain_module: "ModelRegistryDomain")
    #   gen.generate
    #
    class WorkflowGenerator

      # Initializes the workflow generator.
      #
      # @param workflow [Object] the workflow model object; provides +name+ and +steps+
      #   (each step responds to +command+ and/or +branches+)
      # @param domain_module [String] the Ruby module name to wrap the generated class in
      def initialize(workflow, domain_module:)
        @workflow = workflow
        @domain_module = domain_module
      end

      # Generates the full Ruby source code for the workflow class.
      #
      # Produces a class under +Domain::Workflows+ with a +STEPS+ constant
      # describing the execution plan and a +call+ method that executes it.
      #
      # @return [String] the generated Ruby source code, newline-terminated
      def generate
        lines = []
        lines << "module #{@domain_module}"
        lines << "  module Workflows"
        lines << "    class #{@workflow.name}"
        lines << "      unless defined?(STEPS)"
        lines << "        STEPS = ["
        @workflow.steps.each do |step|
          lines.concat(step_lines(step, "          "))
        end
        lines << "        ].freeze"
        lines << "      end"
        lines << ""
        lines << "      attr_reader :results"
        lines << ""
        lines << "      def call(**attrs)"
        lines << "        @results = []"
        lines << "        # Execute steps in sequence, evaluate branches"
        lines << "        self"
        lines << "      end"
        lines << "    end"
        lines << "  end"
        lines << "end"
        lines.join("\n") + "\n"
      end

      private

      # Generates the hash literal lines for a single workflow step.
      #
      # Handles three step types:
      # - Command steps: +{ command: "CommandName" }+
      # - Branch steps: +{ branch: { spec: ..., when_satisfied: [...], otherwise: [...] } }+
      # - Fallback: converts the step to a string and wraps as a command reference
      #
      # @param step [Object] a workflow step object; may respond to +command+ and/or +branches+
      # @param indent [String] the whitespace prefix for each generated line
      # @return [Array<String>] lines of Ruby source code representing the step hash
      def step_lines(step, indent)
        if step.is_a?(BluebookModel::Behavior::CommandStep)
          ["#{indent}{ command: #{step.command.inspect} },"]
        elsif step.respond_to?(:branches) && step.branches
          lines = ["#{indent}{ branch: {"]
          step.branches.each do |branch|
            if branch.respond_to?(:spec) && branch.spec
              lines << "#{indent}    spec: #{branch.spec.inspect},"
              lines << "#{indent}    when_satisfied: #{branch.steps.map { |s| { command: s.command } }.inspect},"
            else
              lines << "#{indent}    otherwise: #{branch.steps.map { |s| { command: s.command } }.inspect},"
            end
          end
          lines << "#{indent}} },"
          lines
        else
          ["#{indent}{ command: #{step.to_s.inspect} },"]
        end
      end
    end
    end
  end
end
