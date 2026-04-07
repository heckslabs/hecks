# Hecks::Chapters::Kernel::DslBuildersParagraph
#
# Paragraph describing the DSL builder classes that parse domain
# definitions into IR. These are the entry points for Hecks.domain {},
# aggregate {}, command {}, etc. Covers DomainBuilder, AggregateBuilder,
# and all sub-builders (command, event, entity, value object, policy,
# lifecycle, read model, service, workflow, bluebook, rebuilder).
#
#   Hecks::Chapters::Kernel::DslBuildersParagraph.define(builder)
#
module Hecks
  module Chapters
    module Kernel
      module DslBuildersParagraph
        def self.define(b)
          b.aggregate "DomainBuilder", "Top-level DSL builder that collects aggregates, policies, services, and workflows into a Domain IR" do
            attribute :name, String
            attribute :version, String
            command("DefineDomain") { attribute :name, String; attribute :version, String }
            command("AddAggregate") { attribute :name, String; attribute :description, String }
            command("AddPolicy") { attribute :name, String; attribute :event_name, String }
            command("AddService") { attribute :name, String }
            command("AddWorkflow") { attribute :name, String }
            command("BuildDomain") { attribute :builder_id, String }
          end

          b.aggregate "AggregateBuilder", "DSL builder for aggregate roots: attributes, commands, value objects, entities, policies, and lifecycles" do
            attribute :name, String
            command("DefineAggregate") { attribute :name, String }
            command("AddAttribute") { attribute :name, String; attribute :type, String }
            command("AddCommand") { attribute :name, String }
            command("AddValueObject") { attribute :name, String }
            command("AddEntity") { attribute :name, String }
            command("BuildAggregate") { attribute :builder_id, String }
          end

          b.aggregate "BehaviorMethods", "Mixin providing command, policy, lifecycle, and subscriber DSL to AggregateBuilder" do
            command("DefineCommand") { attribute :name, String }
            command("DefinePolicy") { attribute :name, String; attribute :event_name, String }
            command("DefineLifecycle") { attribute :field, String; attribute :default_state, String }
          end

          b.aggregate "ConstraintMethods", "Mixin providing validation and invariant DSL to AggregateBuilder" do
            command("AddValidation") { attribute :field, String; attribute :rules, String }
            command("AddInvariant") { attribute :name, String; attribute :expression, String }
          end

          b.aggregate "QueryMethods", "Mixin providing scope and query DSL to AggregateBuilder" do
            command("DefineScope") { attribute :name, String; attribute :conditions, String }
            command("DefineQuery") { attribute :name, String; attribute :return_type, String }
          end

          b.aggregate "ImplicitSyntax", "Method-missing DSL sugar: PascalCase creates value objects, lowercase creates commands" do
            command("InferFromMethodMissing") { attribute :name, String }
          end

          b.aggregate "StrategicBuilders", "Domain-level strategic DDD builders: ACL, shared kernel, ports, published events" do
            command("DefineACL") { attribute :name, String; attribute :translations, String }
            command("DefineSharedKernel") { attribute :domain_id, String }
            command("DefineDrivingPort") { attribute :name, String }
            command("DefineDrivenPort") { attribute :name, String }
          end

          b.aggregate "CommandBuilder", "DSL builder for command definitions: attributes, guards, actors, and handler blocks" do
            attribute :name, String
            command("DefineCommand") { attribute :name, String }
            command("AddGuard") { attribute :policy_name, String }
            command("AddActor") { attribute :actor_name, String }
          end

          b.aggregate "EventBuilder", "DSL builder for explicit domain event declarations with typed attributes" do
            attribute :name, String
            command("DefineEvent") { attribute :name, String }
          end

          b.aggregate "ValueObjectBuilder", "DSL builder for immutable value objects with attributes and invariants" do
            attribute :name, String
            command("DefineValueObject") { attribute :name, String }
          end

          b.aggregate "EntityBuilder", "DSL builder for identity-bearing sub-entities within aggregates" do
            attribute :name, String
            command("DefineEntity") { attribute :name, String }
          end

          b.aggregate "PolicyBuilder", "DSL builder for reactive policies binding events to trigger commands" do
            attribute :name, String
            command("DefinePolicy") { attribute :name, String; attribute :event_name, String; attribute :trigger, String }
          end

          b.aggregate "LifecycleBuilder", "DSL builder for state machine declarations with command-to-state transitions" do
            attribute :field, String
            attribute :default_state, String
            command("AddTransition") { attribute :command_name, String; attribute :target_state, String }
          end

          b.aggregate "ReadModelBuilder", "DSL builder for CQRS read model projections from domain events" do
            attribute :name, String
            command("DefineReadModel") { attribute :name, String }
            command("AddProjection") { attribute :event_name, String }
          end

          b.aggregate "ServiceBuilder", "DSL builder for domain services that orchestrate cross-aggregate operations" do
            attribute :name, String
            command("DefineService") { attribute :name, String }
          end

          b.aggregate "WorkflowBuilder", "DSL builder for multi-step workflows with command steps and conditional branches" do
            attribute :name, String
            command("DefineWorkflow") { attribute :name, String }
            command("AddStep") { attribute :command_name, String }
            command("AddBranch") { attribute :spec_name, String }
          end

          b.aggregate "BluebookBuilder", "DSL builder for composing multiple domains into a single Bluebook structure" do
            attribute :name, String
            command("DefineChapter") { attribute :name, String }
            command("BuildBluebook") { attribute :builder_id, String }
          end

          b.aggregate "AggregateRebuilder", "Reconstructs an AggregateBuilder from a built Aggregate IR for round-trip editing" do
            command("RebuildFromAggregate") { attribute :aggregate_id, String }
          end

          b.aggregate "Describable", "Mixin adding description keyword to any DSL builder for aggregate documentation" do
            command("SetDescription") { attribute :text, String }
          end

          b.aggregate "AttributeCollector", "Shared mixin providing attribute and list_of DSL with type resolution to builders" do
            command("CollectAttribute") { attribute :name, String; attribute :type, String }
          end
        end
      end
    end
  end
end
