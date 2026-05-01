# Hecks::Chapters::Bluebook::DslInternalsParagraph
#
# Paragraph covering DSL internal classes: the collectors, mixins,
# and builder methods that power the Bluebook DSL evaluation
# (attribute collection, behavior methods, constraints, queries,
# implicit syntax, steps, describable, and top-level builder wiring).
#
#   Hecks::Chapters::Bluebook::DslInternalsParagraph.define(builder)
#
module Hecks
  module Chapters
    module Bluebook
      module DslInternalsParagraph
        def self.define(b)
          b.aggregate "AggregateRebuilder", "Rebuilds aggregate IR from modified DSL definitions" do
            command("RebuildAggregate") { attribute :aggregate_id, String }
          end

          b.aggregate "AttributeCollector", "Collects typed attributes during DSL block evaluation" do
            command("CollectAttribute") { attribute :name, String; attribute :type, String }
          end

          b.aggregate "BehaviorMethods", "DSL mixin providing command, event, and policy definition methods" do
            command("DefineBehaviorMethod") { attribute :name, String; attribute :kind, String }
          end

          b.aggregate "ConstraintMethods", "DSL mixin providing validation and invariant definition methods" do
            command("DefineConstraintMethod") { attribute :name, String; attribute :rule, String }
          end

          b.aggregate "ImplicitSyntax", "Convention-based implicit DSL shortcuts for common patterns" do
            command("ApplyImplicitSyntax") { attribute :aggregate_id, String }
          end

          b.aggregate "QueryMethods", "DSL mixin providing query, scope, and specification methods" do
            command("DefineQueryMethod") { attribute :name, String; attribute :return_type, String }
          end

          b.aggregate "StepCollector", "Collects workflow and saga steps during DSL evaluation" do
            command("CollectStep") { attribute :name, String; attribute :action, String }
          end

          b.aggregate "Describable", "Shared mixin adding description support to DSL objects" do
            command("SetDescription") { attribute :text, String }
          end

          b.aggregate "BluebookBuilderMethods", "Top-level Hecks.bluebook method for defining domains" do
            command("DefineDomainEntry") { attribute :name, String }
          end
        end
      end
    end
  end
end
