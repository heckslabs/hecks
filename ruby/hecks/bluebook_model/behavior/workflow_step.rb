module Hecks
  module BluebookModel
    module Behavior
      # Hecks::BluebookModel::Behavior::WorkflowStep
      #
      # Base class for workflow steps. Subclasses represent commands, branches,
      # and scheduled tasks within a workflow definition.
      #
      class WorkflowStep
      end

      # Hecks::BluebookModel::Behavior::CommandStep
      #
      # A workflow step that dispatches a named command with an optional attribute mapping.
      #
      class CommandStep < WorkflowStep
        attr_reader :command, :mapping

        def initialize(command:, mapping: {})
          @command = command.to_s
          @mapping = mapping
        end
      end

      # Hecks::BluebookModel::Behavior::BranchStep
      #
      # A workflow step that conditionally routes to if_steps or else_steps based on a spec.
      #
      class BranchStep < WorkflowStep
        attr_reader :spec, :if_steps, :else_steps

        def initialize(spec:, if_steps: [], else_steps: [])
          @spec = spec
          @if_steps = if_steps
          @else_steps = else_steps
        end
      end

      # Hecks::BluebookModel::Behavior::ScheduledStep
      #
      # A workflow step that finds aggregates matching a query or spec and triggers a command.
      #
      class ScheduledStep < WorkflowStep
        attr_reader :name, :find_aggregate, :find_spec, :find_query, :trigger

        def initialize(name:, find_aggregate:, find_spec: nil, find_query: nil, trigger:)
          @name = name
          @find_aggregate = find_aggregate
          @find_spec = find_spec
          @find_query = find_query
          @trigger = trigger
        end
      end
    end
  end
end
