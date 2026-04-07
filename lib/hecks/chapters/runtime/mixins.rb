# = Hecks::Chapters::Runtime::Mixins
#
# Self-describing sub-chapter for runtime mixins: aggregate model,
# command dispatch, reference validation, lifecycle steps, and
# composite specification objects.
#
#   Hecks::Chapters::Runtime::Mixins.define(builder)
#
module Hecks
  module Chapters
    module Runtime
      # Hecks::Chapters::Runtime::Mixins
      #
      # Bluebook sub-chapter for runtime mixins: aggregate model, command dispatch, and specification objects.
      #
      module Mixins
        def self.define(b)
          b.aggregate "ModelMixinInternal", "Aggregate model mixin: attributes, equality, serialization" do
            command("Initialize") { attribute :attributes, String }
            command("Serialize") { attribute :format, String }
          end

          b.aggregate "DispatchMixin", "Command dispatch mixin" do
            command("Dispatch") { attribute :command_name, String; attribute :payload, String }
          end

          b.aggregate "ReferenceValidation", "Validates references exist before dispatch" do
            command("Validate") { attribute :reference_name, String; attribute :id, String }
          end

          b.aggregate "LifecycleSteps", "Lifecycle state transition steps" do
            command("Transition") { attribute :from_state, String; attribute :to_state, String }
          end

          b.aggregate "AndSpecification", "Composite AND specification" do
            command("Satisfied") { attribute :candidate, String }
          end

          b.aggregate "OrSpecification", "Composite OR specification" do
            command("Satisfied") { attribute :candidate, String }
          end

          b.aggregate "NotSpecification", "Composite NOT specification" do
            command("Satisfied") { attribute :candidate, String }
          end

          b.aggregate "BreakingBumper", "Auto-bumps version on breaking changes" do
            command("Bump") { attribute :domain_name, String }
          end

          b.aggregate "BreakingClassifier", "Classifies domain changes as breaking/non-breaking" do
            command("Classify") { attribute :diff, String }
          end

          b.aggregate "Command", "Mixin orchestrating command lifecycle: guard, validate, call, persist, emit event" do
            command("Emits") { attribute :event_names, String }
            command("Call") { attribute :attrs, String }
          end

          b.aggregate "Model", "Mixin for aggregate classes providing attribute DSL, UUID identity, and auto-discovery" do
            command("Attribute") { attribute :name, String; attribute :default, String }
            command("RebuildInitializer") { }
          end

          b.aggregate "Query", "Mixin for query classes providing repository wiring and QueryBuilder delegation" do
            command("Call") { attribute :params, String }
          end

          b.aggregate "Specification", "Mixin for composable business rule predicates with and/or/not operators" do
            command("SatisfiedBy") { attribute :candidate, String }
          end

          b.aggregate "Dispatch", "Event construction and persistence helpers for command execution" do
            command("EmitEvent") { }
            command("PersistAggregate") { }
          end

          b.aggregate "Validation", "Pre/postcondition DSL and enforcement for command objects" do
            command("Precondition") { attribute :message, String }
            command("Postcondition") { attribute :message, String }
          end

          b.aggregate "RuntimeAttributeDefinition", "Struct wrapping a single model attribute's name, default, and freeze flag" do
            command("Define") { attribute :name, String; attribute :default, String }
          end

          b.aggregate "WorkflowStepCompat", "Deprecation shim for legacy workflow_step API" do
            command("Register") { attribute :target_class, String }
          end

          b.aggregate "ConnectionConfigCompat", "Deprecation shim for legacy connection_config API" do
            command("Register") { attribute :target_class, String }
          end
        end
      end
    end
  end
end
