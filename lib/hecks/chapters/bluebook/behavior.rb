# Hecks::Chapters::Bluebook::BehaviorParagraph
#
# Paragraph covering behavior IR nodes: commands, events, queries,
# policies, services, sagas, workflows, and other action-oriented
# building blocks of a domain model.
#
#   Hecks::Chapters::Bluebook::BehaviorParagraph.define(builder)
#
module Hecks
  module Chapters
    module Bluebook
      module BehaviorParagraph
        def self.define(b)
          b.aggregate "Command", "Intent to change aggregate state, carries attributes" do
            command("DefineCommand") { attribute :name, String; attribute :aggregate_id, String }
          end

          b.aggregate "DomainEvent", "Fact that something happened, emitted after command execution" do
            command("DefineEvent") { attribute :name, String; attribute :aggregate_id, String }
          end

          b.aggregate "Query", "Read-side request returning data without side effects" do
            command("DefineQuery") { attribute :name, String; attribute :return_type, String }
          end

          b.aggregate "Policy", "Reactive rule triggered by an event, dispatches a command" do
            command("DefinePolicy") { attribute :name, String; attribute :event_name, String; attribute :trigger_command, String }
          end

          b.aggregate "Service", "Stateless domain operation spanning multiple aggregates" do
            command("DefineService") { attribute :name, String; attribute :operation, String }
          end

          b.aggregate "Condition", "Predicate guard on a command or workflow step" do
            command("DefineCondition") { attribute :name, String; attribute :expression, String }
          end

          b.aggregate "EventSubscriber", "Handler that reacts to domain events" do
            command("DefineSubscriber") { attribute :name, String; attribute :event_name, String }
          end

          b.aggregate "Specification", "Composable boolean predicate for domain rules" do
            command("DefineSpecification") { attribute :name, String; attribute :predicate, String }
          end

          b.aggregate "Saga", "Multi-step distributed process with compensation" do
            command("DefineSaga") { attribute :name, String; attribute :aggregate_id, String }
          end

          b.aggregate "SagaStep", "Single step within a saga, with action and compensate" do
            command("DefineSagaStep") { attribute :saga_id, String; attribute :action, String; attribute :compensate, String }
          end

          b.aggregate "Workflow", "Multi-step process with branching and conditions" do
            command("DefineWorkflow") { attribute :name, String; attribute :aggregate_id, String }
          end

          b.aggregate "WorkflowStep", "Single step within a workflow, with optional condition" do
            command("DefineWorkflowStep") { attribute :workflow_id, String; attribute :command_name, String }
          end

          b.aggregate "Behavior", "Namespace module for behavior IR nodes: commands, events, policies" do
            command("Define") { attribute :name, String }
          end

          b.aggregate "BidirectionalReferences", "Detects and rejects domains where two aggregates reference each other" do
            command("DetectBidirectional") { attribute :domain_id, String }
          end
        end
      end
    end
  end
end
