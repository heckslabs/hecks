# Hecks::Chapters::Bluebook::StructureParagraph
#
# Paragraph covering structure IR nodes: the data-shape building
# blocks that make up a domain model (aggregates, entities, value
# objects, attributes, references, lifecycles, etc.).
#
#   Hecks::Chapters::Bluebook::StructureParagraph.define(builder)
#
module Hecks
  module Chapters
    module Bluebook
      module StructureParagraph
        def self.define(b)
          b.aggregate "BluebookStructure", "Root container for composed system of chapters" do
            command("BuildStructure") { attribute :domain_id, String }
          end

          b.aggregate "Actor", "External person or system that initiates commands" do
            command("DefineActor") { attribute :name, String; attribute :role, String }
          end

          b.aggregate "Attribute", "Typed field on an aggregate, entity, or value object" do
            command("DefineAttribute") { attribute :name, String; attribute :type, String }
          end

          b.aggregate "ComputedAttribute", "Derived field calculated from other attributes" do
            command("DefineComputedAttribute") { attribute :name, String; attribute :expression, String }
          end

          b.aggregate "Entity", "Identity-bearing object within an aggregate boundary" do
            command("DefineEntity") { attribute :name, String; attribute :aggregate_id, String }
          end

          b.aggregate "ExternalSystem", "Third-party system integrated via anti-corruption layer" do
            command("DefineExternalSystem") { attribute :name, String; attribute :adapter, String }
          end

          b.aggregate "Invariant", "Business rule that must hold true for aggregate consistency" do
            command("DefineInvariant") { attribute :name, String; attribute :expression, String }
          end

          b.aggregate "Lifecycle", "State machine defining aggregate lifecycle transitions" do
            command("DefineLifecycle") { attribute :aggregate_id, String; attribute :initial_state, String }
          end

          b.aggregate "ReadModel", "Denormalized projection optimized for queries" do
            command("DefineReadModel") { attribute :name, String; attribute :source_aggregate, String }
          end

          b.aggregate "Reference", "Association between aggregates (composition or aggregation)" do
            command("DefineReference") { attribute :from, String; attribute :to, String; attribute :kind, String }
          end

          b.aggregate "Scope", "Named query scope on an aggregate or read model" do
            command("DefineScope") { attribute :name, String; attribute :filter, String }
          end

          b.aggregate "StateTransition", "Named edge in a lifecycle state machine" do
            command("DefineStateTransition") { attribute :from_state, String; attribute :to_state, String; attribute :event, String }
          end

          b.aggregate "ValidationNode", "Declarative validation rule on an attribute or aggregate" do
            command("DefineValidation") { attribute :name, String; attribute :rule, String }
          end

          b.aggregate "ValueObject", "Immutable, identity-less domain concept defined by its attributes" do
            command("DefineValueObject") { attribute :name, String; attribute :aggregate_id, String }
          end

          b.aggregate "Paragraph", "Named group of aggregates within a chapter" do
            command("DefineParagraph") { attribute :name, String }
          end

          b.aggregate "Validation", "Validation rule IR node for aggregate attribute constraints" do
            command("DefineValidationRule") { attribute :attribute_name, String; attribute :rule, String }
          end

          b.aggregate "CommandStep", "Workflow step that dispatches a named command" do
            command("DefineCommandStep") { attribute :command, String; attribute :mapping, String }
          end

          b.aggregate "BranchStep", "Workflow step that conditionally routes based on a spec" do
            command("DefineBranchStep") { attribute :spec, String }
          end

          b.aggregate "ScheduledStep", "Workflow step that finds aggregates and triggers a command" do
            command("DefineScheduledStep") { attribute :name, String; attribute :trigger, String }
          end

          b.aggregate "JsonAttribute", "JSON type accepted as attribute type, round-trips through SQL generation" do
            command("DefineJsonAttribute") { attribute :name, String; attribute :aggregate_id, String }
          end

          b.aggregate "DateTypes", "Date and DateTime types stored correctly in attribute IR" do
            command("DefineDateType") { attribute :name, String; attribute :type, String }
          end
        end
      end
    end
  end
end
