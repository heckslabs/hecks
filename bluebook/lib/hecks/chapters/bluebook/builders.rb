# Hecks::Chapters::Bluebook::BuildersParagraph
#
# Paragraph covering DSL builder classes: the fluent interfaces
# users interact with to define domains, aggregates, commands,
# events, policies, workflows, and other domain constructs.
#
#   Hecks::Chapters::Bluebook::BuildersParagraph.define(builder)
#
module Hecks
  module Chapters
    module Bluebook
      module BuildersParagraph
        def self.define(b)
          b.aggregate "DomainBuilder", "Top-level DSL builder that collects aggregates, policies, and services into a Domain IR" do
            command("BuildDomain") { attribute :name, String; attribute :version, String }
          end

          b.aggregate "AggregateBuilder", "DSL builder for aggregate roots with commands, events, and lifecycle" do
            command("BuildAggregate") { attribute :name, String }
          end

          b.aggregate "CommandBuilder", "DSL builder for command definitions with typed attributes" do
            command("BuildCommand") { attribute :name, String; attribute :aggregate_id, String }
          end

          b.aggregate "EntityBuilder", "DSL builder for identity-bearing entities within an aggregate" do
            command("BuildEntity") { attribute :name, String; attribute :aggregate_id, String }
          end

          b.aggregate "EventBuilder", "DSL builder for domain event definitions" do
            command("BuildEvent") { attribute :name, String }
          end

          b.aggregate "ValueObjectBuilder", "DSL builder for immutable value objects with attributes and invariants" do
            command("BuildValueObject") { attribute :name, String }
          end

          b.aggregate "PolicyBuilder", "DSL builder for reactive policies triggered by events" do
            command("BuildPolicy") { attribute :name, String; attribute :event_name, String }
          end

          b.aggregate "ServiceBuilder", "DSL builder for stateless domain services spanning aggregates" do
            command("BuildService") { attribute :name, String }
          end

          b.aggregate "WorkflowBuilder", "DSL builder for multi-step workflows with branching" do
            command("BuildWorkflow") { attribute :name, String }
          end

          b.aggregate "LifecycleBuilder", "DSL builder for state machine lifecycle definitions" do
            command("BuildLifecycle") { attribute :aggregate_id, String; attribute :initial_state, String }
          end

          b.aggregate "ReadModelBuilder", "DSL builder for denormalized read model projections" do
            command("BuildReadModel") { attribute :name, String }
          end

          b.aggregate "SagaBuilder", "DSL builder for long-running sagas with compensation" do
            command("BuildSaga") { attribute :name, String }
          end

          b.aggregate "SagaStepBuilder", "DSL builder for individual saga steps with action and compensate" do
            command("BuildSagaStep") { attribute :saga_id, String; attribute :action, String }
          end

          b.aggregate "GlossaryBuilder", "DSL builder for ubiquitous language glossary rules" do
            command("BuildGlossary") { attribute :domain_id, String }
          end

          b.aggregate "ModuleBuilder", "DSL builder for logical sub-groupings within a domain" do
            command("BuildModule") { attribute :name, String }
          end

          b.aggregate "AclBuilder", "DSL builder for anti-corruption layer definitions" do
            command("BuildAcl") { attribute :name, String; attribute :external_system, String }
          end

          b.aggregate "BranchBuilder", "DSL builder for conditional branches within workflows" do
            command("BuildBranch") { attribute :condition, String }
          end

          b.aggregate "ScheduledStepBuilder", "DSL builder for time-triggered workflow steps" do
            command("BuildScheduledStep") { attribute :interval, String }
          end
        end
      end
    end
  end
end
