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

          b.aggregate "SinatraGenerator", "Generates Sinatra server wrapper for domain" do
            command("GenerateSinatra") { attribute :domain_id, String; attribute :output_dir, String }
          end

          b.aggregate "ConfigGenerator", "Generates configuration initializer for domain" do
            command("GenerateConfig") { attribute :domain_id, String; attribute :output_dir, String }
          end

          b.aggregate "LlmAggregateDescriber", "Renders aggregate sections as plain text for llms.txt" do
            command("Describe") { attribute :aggregate_id, String }
          end

          b.aggregate "LlmPolicyDescriber", "Renders policies and reactive flows as plain text for llms.txt" do
            command("Describe") { attribute :domain_id, String }
          end

          b.aggregate "LlmValidationDescriber", "Renders validation rules and invariants as plain text for llms.txt" do
            command("Describe") { attribute :aggregate_id, String }
          end

          b.aggregate "ConstructorGeneration", "Generates initialize method with keyword args for aggregates" do
            command("GenerateConstructor") { attribute :aggregate_id, String }
          end

          b.aggregate "InvariantGeneration", "Generates check_invariants! method for aggregate classes" do
            command("GenerateInvariants") { attribute :aggregate_id, String }
          end

          b.aggregate "ValidationGeneration", "Generates validate! method for aggregate classes" do
            command("GenerateValidations") { attribute :aggregate_id, String }
          end

          b.aggregate "OpenApiPathBuilder", "Builds OpenAPI path entries from domain aggregates" do
            command("BuildPaths") { attribute :aggregate_id, String }
          end

          b.aggregate "OpenApiResponseHelpers", "Shared OpenAPI response and parameter helpers" do
            command("BuildResponse") { attribute :response_type, String }
          end

          b.aggregate "OpenApiSchemaBuilder", "Builds OpenAPI component schemas from domain aggregates" do
            command("BuildSchema") { attribute :aggregate_id, String }
          end

          b.aggregate "SqlAdapterGenerator", "Generates Sequel-based persistence adapter class" do
            command("GenerateSqlAdapter") { attribute :aggregate_id, String; attribute :output_dir, String }
          end

          b.aggregate "SqlMigrationGenerator", "Generates SQL CREATE/ALTER TABLE migration files from domain diffs" do
            command("GenerateSqlMigration") { attribute :domain_id, String; attribute :output_dir, String }
          end

          b.aggregate "RailsGenerator", "Generates a complete Rails app wired to the domain gem" do
            command("GenerateRailsApp") { attribute :domain_id, String; attribute :output_dir, String }
          end

          b.aggregate "JsonSchemaGenerator", "Generates JSON Schema for aggregate commands and value objects" do
            command("GenerateJsonSchema") { attribute :aggregate_id, String; attribute :output_dir, String }
          end

          b.aggregate "OpenApiGenerator", "Generates OpenAPI 3.0 spec with paths, request bodies, and schemas" do
            command("GenerateOpenApi") { attribute :domain_id, String; attribute :output_dir, String }
          end

          b.aggregate "TypescriptGenerator", "Generates TypeScript interfaces for aggregates, commands, and value objects" do
            command("GenerateTypeScript") { attribute :domain_id, String; attribute :output_dir, String }
          end

          b.aggregate "RouteBuilder", "Generates HTTP route definitions from domain commands and queries" do
            command("BuildRoutes") { attribute :domain_id, String }
          end

          b.aggregate "RpcDiscovery", "Generates machine-readable RPC manifest of commands and queries" do
            command("GenerateRpcManifest") { attribute :domain_id, String }
          end

          b.aggregate "CallPreservation", "Preserves hand-written call method bodies during code regeneration" do
            command("PreserveCalls") { attribute :source, String; attribute :generated, String }
          end

          b.aggregate "PathTraversal", "Validates output paths to prevent directory traversal attacks" do
            command("ValidatePath") { attribute :path, String }
          end

          b.aggregate "ExampleAppWriter", "Writes example application demonstrating domain usage" do
            command("WriteApp") { attribute :domain_id, String; attribute :output_dir, String }
          end

          b.aggregate "ExampleBluebookWriter", "Writes example Bluebook DSL file for a domain" do
            command("WriteBluebook") { attribute :domain_id, String; attribute :output_dir, String }
          end

          b.aggregate "CliGenerator", "Generates Thor CLI subcommands from chapter IR" do
            command("GenerateCli") { attribute :domain_id, String }
          end

          b.aggregate "CliTypeMapper", "Maps IR attribute types to Thor option types" do
            command("MapType") { attribute :type, String }
          end
        end
      end
    end
  end
end
