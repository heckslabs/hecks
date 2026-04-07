# Hecks::Chapters::Bootstrap::DslBuildersParagraph
#
# Paragraph covering the DSL builder hierarchy: the classes that
# translate block syntax into domain model IR nodes. These must
# load before any chapter can call DomainBuilder.new.
#
#   Hecks::Chapters::Bootstrap::DslBuildersParagraph.define(builder)
#
module Hecks
  module Chapters
    module Bootstrap
      module DslBuildersParagraph
        def self.define(b)
          b.aggregate "AggregateBuilder", "Builds aggregate IR from DSL block: attributes, commands, events, policies, lifecycle" do
            command("AddAttribute") { attribute :name, String; attribute :type, String }
            command("AddCommand") { attribute :name, String }
            command("AddEvent") { attribute :name, String }
            command("AddPolicy") { attribute :name, String }
          end

          b.aggregate "AggregateRebuilder", "Reopens an existing aggregate to add or modify its definition" do
            command("Rebuild") { attribute :aggregate_name, String }
          end

          b.aggregate "AttributeCollector", "Collects typed attributes for commands, events, and value objects" do
            command("Collect") { attribute :name, String; attribute :type, String }
          end

          b.aggregate "Describable", "Mixin providing description keyword to all DSL blocks" do
            command("Describe") { attribute :text, String }
          end

          b.aggregate "EventBuilder", "Builds event IR from DSL block with attributes" do
            command("Build") { attribute :name, String }
          end

          b.aggregate "CommandBuilder", "Builds command IR from DSL block with attributes, guards, actors, and read models" do
            command("Build") { attribute :name, String }
          end

          b.aggregate "ValueObjectBuilder", "Builds value object IR: immutable nested type with attributes and invariants" do
            command("Build") { attribute :name, String }
          end

          b.aggregate "EntityBuilder", "Builds entity IR: identity-bearing sub-object within an aggregate" do
            command("Build") { attribute :name, String }
          end

          b.aggregate "PolicyBuilder", "Builds policy IR: reactive rule linking events to commands" do
            command("Build") { attribute :name, String }
          end

          b.aggregate "LifecycleBuilder", "Builds lifecycle IR: state machine with transitions" do
            command("Build") { attribute :attribute_name, String; attribute :default, String }
          end

          b.aggregate "ReadModelBuilder", "Builds read model IR: denormalized projection from events" do
            command("Build") { attribute :name, String }
          end

          b.aggregate "ServiceBuilder", "Builds domain service IR: cross-aggregate operations" do
            command("Build") { attribute :name, String }
          end

          b.aggregate "WorkflowBuilder", "Builds workflow IR: multi-step command sequences with branching" do
            command("Build") { attribute :name, String }
          end
        end
      end
    end
  end
end
