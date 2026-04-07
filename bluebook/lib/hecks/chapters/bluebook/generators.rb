# Hecks::Chapters::Bluebook::GeneratorsParagraph
#
# Paragraph covering code generator classes: the visitors that
# walk domain IR and emit Ruby source, specs, adapters, docs,
# and infrastructure files for a domain gem.
#
#   Hecks::Chapters::Bluebook::GeneratorsParagraph.define(builder)
#
module Hecks
  module Chapters
    module Bluebook
      module GeneratorsParagraph
        def self.define(b)
          b.aggregate "AggregateGenerator", "Generates aggregate root Ruby class from IR" do
            command("GenerateAggregate") { attribute :aggregate_id, String; attribute :output_dir, String }
          end

          b.aggregate "CommandGenerator", "Generates command class with typed attributes and validations" do
            command("GenerateCommand") { attribute :command_id, String; attribute :output_dir, String }
          end

          b.aggregate "EntityGenerator", "Generates entity class within an aggregate boundary" do
            command("GenerateEntity") { attribute :entity_id, String; attribute :output_dir, String }
          end

          b.aggregate "EventGenerator", "Generates domain event class from command inference" do
            command("GenerateEvent") { attribute :event_id, String; attribute :output_dir, String }
          end

          b.aggregate "ValueObjectGenerator", "Generates immutable value object class" do
            command("GenerateValueObject") { attribute :value_object_id, String; attribute :output_dir, String }
          end

          b.aggregate "PolicyGenerator", "Generates reactive policy wiring event to command" do
            command("GeneratePolicy") { attribute :policy_id, String; attribute :output_dir, String }
          end

          b.aggregate "ServiceGenerator", "Generates domain service class spanning aggregates" do
            command("GenerateService") { attribute :service_id, String; attribute :output_dir, String }
          end

          b.aggregate "QueryGenerator", "Generates query scope method on aggregate" do
            command("GenerateQuery") { attribute :query_id, String; attribute :output_dir, String }
          end

          b.aggregate "QueryObjectGenerator", "Generates standalone query object class" do
            command("GenerateQueryObject") { attribute :query_id, String; attribute :output_dir, String }
          end

          b.aggregate "WorkflowGenerator", "Generates multi-step workflow orchestration class" do
            command("GenerateWorkflow") { attribute :workflow_id, String; attribute :output_dir, String }
          end

          b.aggregate "LifecycleGenerator", "Generates state machine lifecycle module" do
            command("GenerateLifecycle") { attribute :aggregate_id, String; attribute :output_dir, String }
          end

          b.aggregate "SubscriberGenerator", "Generates event subscriber handler class" do
            command("GenerateSubscriber") { attribute :subscriber_id, String; attribute :output_dir, String }
          end

          b.aggregate "SpecificationGenerator", "Generates composable specification predicate class" do
            command("GenerateSpecification") { attribute :spec_id, String; attribute :output_dir, String }
          end

          b.aggregate "ViewGenerator", "Generates read model view projection class" do
            command("GenerateView") { attribute :view_id, String; attribute :output_dir, String }
          end

          b.aggregate "DomainGemGenerator", "Generates complete domain gem with gemspec and structure" do
            command("GenerateDomainGem") { attribute :domain_id, String; attribute :output_dir, String }
          end

          b.aggregate "SpecGenerator", "Generates RSpec test files for domain constructs" do
            command("GenerateSpec") { attribute :construct_id, String; attribute :output_dir, String }
          end

          b.aggregate "PortGenerator", "Generates port interface for aggregate persistence" do
            command("GeneratePort") { attribute :aggregate_id, String; attribute :output_dir, String }
          end

          b.aggregate "MemoryAdapterGenerator", "Generates in-memory adapter for fast testing" do
            command("GenerateMemoryAdapter") { attribute :aggregate_id, String; attribute :output_dir, String }
          end

          b.aggregate "AutoloadGenerator", "Generates autoload manifest for domain gem modules" do
            command("GenerateAutoload") { attribute :domain_id, String; attribute :output_dir, String }
          end

          b.aggregate "RailsGenerator", "Generates Rails integration files (initializer, routes, controllers)" do
            command("GenerateRails") { attribute :domain_id, String; attribute :output_dir, String }
          end

          b.aggregate "JsonSchemaGenerator", "Generates JSON Schema from domain aggregate structure" do
            command("GenerateJsonSchema") { attribute :aggregate_id, String }
          end

          b.aggregate "OpenapiGenerator", "Generates OpenAPI 3.0 specification from domain IR" do
            command("GenerateOpenapi") { attribute :domain_id, String }
          end

          b.aggregate "TypescriptGenerator", "Generates TypeScript type definitions from domain IR" do
            command("GenerateTypescript") { attribute :domain_id, String; attribute :output_dir, String }
          end

          b.aggregate "RpcDiscovery", "Generates RPC service discovery manifest from domain commands" do
            command("GenerateRpcDiscovery") { attribute :domain_id, String }
          end
        end
      end
    end
  end
end
