# Hecks::Chapters::Bluebook::SpecGeneratorsParagraph
#
# Paragraph covering individual spec generator classes: each
# generator produces an RSpec file for a specific domain construct
# type (aggregate, command, entity, event, lifecycle, policy, port,
# query, scope, service, specification, value object, view, workflow).
#
#   Hecks::Chapters::Bluebook::SpecGeneratorsParagraph.define(builder)
#
module Hecks
  module Chapters
    module Bluebook
      module SpecGeneratorsParagraph
        def self.define(b)
          b.aggregate "AggregateSpec", "Generates RSpec file for aggregate root classes" do
            command("GenerateAggregateSpec") { attribute :aggregate_id, String; attribute :output_dir, String }
          end

          b.aggregate "CommandSpec", "Generates RSpec file for command classes" do
            command("GenerateCommandSpec") { attribute :command_id, String; attribute :output_dir, String }
          end

          b.aggregate "EntitySpec", "Generates RSpec file for entity classes" do
            command("GenerateEntitySpec") { attribute :entity_id, String; attribute :output_dir, String }
          end

          b.aggregate "EventSpec", "Generates RSpec file for domain event classes" do
            command("GenerateEventSpec") { attribute :event_id, String; attribute :output_dir, String }
          end

          b.aggregate "LifecycleSpec", "Generates RSpec file for lifecycle state machines" do
            command("GenerateLifecycleSpec") { attribute :aggregate_id, String; attribute :output_dir, String }
          end

          b.aggregate "PolicySpec", "Generates RSpec file for reactive policy classes" do
            command("GeneratePolicySpec") { attribute :policy_id, String; attribute :output_dir, String }
          end

          b.aggregate "PortSpec", "Generates RSpec file for port interface classes" do
            command("GeneratePortSpec") { attribute :aggregate_id, String; attribute :output_dir, String }
          end

          b.aggregate "QuerySpec", "Generates RSpec file for query scope methods" do
            command("GenerateQuerySpec") { attribute :query_id, String; attribute :output_dir, String }
          end

          b.aggregate "ScopeSpec", "Generates RSpec file for named scope classes" do
            command("GenerateScopeSpec") { attribute :scope_id, String; attribute :output_dir, String }
          end

          b.aggregate "ServiceSpec", "Generates RSpec file for domain service classes" do
            command("GenerateServiceSpec") { attribute :service_id, String; attribute :output_dir, String }
          end

          b.aggregate "SpecificationSpec", "Generates RSpec file for specification predicate classes" do
            command("GenerateSpecificationSpec") { attribute :spec_id, String; attribute :output_dir, String }
          end

          b.aggregate "ValueObjectSpec", "Generates RSpec file for value object classes" do
            command("GenerateValueObjectSpec") { attribute :vo_id, String; attribute :output_dir, String }
          end

          b.aggregate "ViewSpec", "Generates RSpec file for read model view classes" do
            command("GenerateViewSpec") { attribute :view_id, String; attribute :output_dir, String }
          end

          b.aggregate "WorkflowSpec", "Generates RSpec file for workflow classes" do
            command("GenerateWorkflowSpec") { attribute :workflow_id, String; attribute :output_dir, String }
          end
        end
      end
    end
  end
end
