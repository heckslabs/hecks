# Hecks::Chapters::Bluebook
#
# Self-describing domain definition for the Bluebook chapter. Models the
# DSL, IR, compiler, generators, validation, and tooling as aggregates.
#
#   domain = Hecks::Chapters::Bluebook.definition
#   domain.aggregates.map(&:name)
#
module Hecks
  module Chapters
    module Bluebook
      def self.definition
        @definition ||= DSL::DomainBuilder.new("Bluebook").tap { |b|
          b.instance_eval do
            aggregate "Domain" do
              attribute :name, String
              attribute :version, String
              command "DefineDomain" do
                attribute :name, String
                attribute :version, String
              end
              command "ValidateDomain" do
                attribute :domain_id, String
              end
              command "GenerateCode" do
                attribute :domain_id, String
                attribute :target, String
              end
            end

            aggregate "Aggregate" do
              attribute :name, String
              attribute :domain_name, String
              command "AddAggregate" do
                attribute :name, String
                attribute :domain_name, String
              end
              command "AddAttribute" do
                attribute :aggregate_id, String
                attribute :name, String
                attribute :type, String
              end
              command "AddCommand" do
                attribute :aggregate_id, String
                attribute :name, String
              end
              command "AddPolicy" do
                attribute :aggregate_id, String
                attribute :name, String
                attribute :event_name, String
                attribute :trigger_command, String
              end
            end

            aggregate "Grammar" do
              attribute :name, String
              command "RegisterGrammar" do
                attribute :name, String
              end
              command "ParseInput" do
                attribute :grammar_id, String
                attribute :input, String
              end
            end

            aggregate "Compiler" do
              attribute :domain_id, String
              command "BuildDomain" do
                attribute :domain_id, String
                attribute :output_dir, String
              end
              command "LoadDomain" do
                attribute :domain_id, String
              end
            end

            aggregate "Validator" do
              attribute :domain_id, String
              command "RunValidation" do
                attribute :domain_id, String
              end
            end

            aggregate "Visualizer" do
              attribute :domain_id, String
              command "GenerateDiagram" do
                attribute :domain_id, String
              end
            end

            aggregate "Glossary" do
              attribute :domain_id, String
              command "GenerateGlossary" do
                attribute :domain_id, String
              end
            end

            aggregate "DslSerializer" do
              attribute :domain_id, String
              command "SerializeDomain" do
                attribute :domain_id, String
              end
            end

            aggregate "AstExtractor" do
              attribute :source, String
              command "ExtractDomain" do
                attribute :source, String
              end
            end

            aggregate "FlowGenerator" do
              attribute :domain_id, String
              command "TraceFlows" do
                attribute :domain_id, String
              end
            end

            aggregate "LlmsGenerator" do
              attribute :domain_id, String
              command "GenerateLlmsTxt" do
                attribute :domain_id, String
              end
            end

            aggregate "ReadmeGenerator" do
              attribute :root, String
              command "GenerateReadme" do
                attribute :root, String
              end
            end

            aggregate "VerticalSlice" do
              attribute :name, String
              attribute :entry_command, String
              command "ExtractSlices" do
                attribute :domain_id, String
              end
              command "GenerateSliceDiagram" do
                attribute :domain_id, String
              end
            end

            aggregate "EventStorm" do
              attribute :source, String
              command "ParseEventStorm" do
                attribute :source, String
              end
              command "ImportEventStorm" do
                attribute :source, String
                attribute :name, String
              end
            end

            aggregate "Migration" do
              attribute :domain_id, String
              command "DiffDomains" do
                attribute :domain_id, String
              end
              command "RunMigration" do
                attribute :domain_id, String
              end
            end

            aggregate "ContextMap" do
              attribute :domains, String
              command "GenerateContextMap" do
                attribute :domains, String
              end
            end

            aggregate "ValidationRule" do
              attribute :name, String
              attribute :category, String
              command "CheckRule" do
                attribute :domain_id, String
                attribute :rule_name, String
              end
            end

            aggregate "Versioner" do
              attribute :path, String
              command "ComputeVersion" do
                attribute :path, String
              end
            end

            policy "AutoEvent" do
              on "AddedCommand"
              trigger "InferEvent"
            end
          end
        }.build
      end
    end
  end
end
