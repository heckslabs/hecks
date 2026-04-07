# Hecks::Chapters::Bluebook
#
# Self-describing domain definition for the Bluebook chapter. Models the
# DSL, IR, compiler, generators, validation, and tooling as aggregates.
# Organized into paragraphs: Structure, Behavior, Names, Tooling,
# Builders, Generators, GeneratorInternals, SpecGenerators,
# ValidationRules, DslInternals, Serializers, Visualizers, Ast,
# Migrations, Features.
#
#   domain = Hecks::Chapters::Bluebook.definition
#   domain.aggregates.map(&:name)
#
module Hecks
  module Chapters
    require_paragraphs(__FILE__)

    module Bluebook
      def self.definition
        @definition ||= DSL::DomainBuilder.new("Bluebook").tap { |b|
          b.instance_eval do
            aggregate "Domain", "Root of the domain model IR, holds aggregates and policies" do
              attribute :name, String
              attribute :version, String
              command("DefineDomain") { attribute :name, String; attribute :version, String }
              command("ValidateDomain") { attribute :domain_id, String }
              command("GenerateCode") { attribute :domain_id, String; attribute :target, String }
            end

            aggregate "Aggregate", "DDD aggregate root with commands, events, and lifecycle" do
              attribute :name, String
              attribute :domain_name, String
              command("AddAggregate") { attribute :name, String; attribute :domain_name, String }
              command("AddAttribute") { attribute :aggregate_id, String; attribute :name, String; attribute :type, String }
              command("AddCommand") { attribute :aggregate_id, String; attribute :name, String }
              command("AddPolicy") { attribute :aggregate_id, String; attribute :name, String; attribute :event_name, String; attribute :trigger_command, String }
            end

            aggregate "Grammar", "DSL grammar definition for parsing domain definitions" do
              attribute :name, String
              command("RegisterGrammar") { attribute :name, String }
              command("ParseInput") { attribute :grammar_id, String; attribute :input, String }
            end

            aggregate "Compiler", "Builds domain gems from IR and loads domains" do
              attribute :domain_id, String
              command("BuildDomain") { attribute :domain_id, String; attribute :output_dir, String }
            end

            aggregate "Validator", "Runs validation rules against domain IR" do
              attribute :domain_id, String
              command("RunValidation") { attribute :domain_id, String }
            end

            aggregate "Visualizer", "Generates Mermaid diagrams from domain IR" do
              attribute :domain_id, String
              command("GenerateDiagram") { attribute :domain_id, String }
            end

            aggregate "Glossary", "Generates Ubiquitous Language glossary from domain IR" do
              attribute :domain_id, String
              command("GenerateGlossary") { attribute :domain_id, String }
            end

            aggregate "DslSerializer", "Serializes domain IR back to DSL source" do
              attribute :domain_id, String
              command("SerializeDomain") { attribute :domain_id, String }
            end

            aggregate "AstExtractor", "Extracts domain definitions from Ruby AST" do
              attribute :source, String
              command("ExtractDomain") { attribute :source, String }
            end

            aggregate "FlowGenerator", "Traces reactive event flows across policies" do
              attribute :domain_id, String
              command("TraceFlows") { attribute :domain_id, String }
            end

            aggregate "LlmsGenerator", "Generates llms.txt from domain IR" do
              attribute :domain_id, String
              command("GenerateLlmsTxt") { attribute :domain_id, String }
            end

            aggregate "ReadmeGenerator", "Generates README from domain IR" do
              attribute :root, String
              command("GenerateReadme") { attribute :root, String }
            end

            aggregate "VerticalSlice", "Cross-cutting slice through command/event chain" do
              attribute :name, String
              attribute :entry_command, String
              command("ExtractSlices") { attribute :domain_id, String }
            end

            aggregate "EventStorm", "Imports event storming sessions into domain IR" do
              attribute :source, String
              command("ParseEventStorm") { attribute :source, String }
              command("ImportEventStorm") { attribute :source, String; attribute :name, String }
            end

            aggregate "Migration", "Diffs domain versions and generates migrations" do
              attribute :domain_id, String
              command("DiffDomains") { attribute :domain_id, String }
              command("RunMigration") { attribute :domain_id, String }
            end

            aggregate "ContextMap", "Generates context map across multiple domains" do
              attribute :domains, String
              command("GenerateContextMap") { attribute :domains, String }
            end

            aggregate "ValidationRule", "Single validation rule within the validator" do
              attribute :name, String
              attribute :category, String
              command("CheckRule") { attribute :domain_id, String; attribute :rule_name, String }
            end

            aggregate "Versioner", "Computes CalVer version from git history" do
              attribute :path, String
              command("ComputeVersion") { attribute :path, String }
            end

            policy "AutoEvent" do
              on "AddedCommand"
              trigger "InferEvent"
            end
          end

          Chapters.define_paragraphs(Bluebook, b)
        }.build
      end
    end
  end
end
