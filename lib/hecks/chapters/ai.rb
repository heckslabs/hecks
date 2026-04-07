# Hecks::Chapters::AI
#
# Self-describing chapter definition for the hecks_ai gem.
# Enumerates every class and module under hecks_ai/lib/ as
# aggregates with their key commands. IDE aggregates are split
# into ai_ide.rb to stay within the 200-line code limit.
#
#   domain = Hecks::Chapters::AI.definition
#   domain.aggregates.map(&:name)
#   # => ["McpServer", "DomainServer", "GovernanceGuard", ...]
#
require "bluebook"

module Hecks
  module Chapters
    require_paragraphs(__FILE__)

    module AI
      def self.summary = "AI integration for Hecks"

      def self.definition
        Hecks::DSL::DomainBuilder.new("AI").tap { |b|
          b.aggregate "McpServer" do
            description "MCP server exposing Workshop API as tools for AI agents"
            command "Start"
            command "RegisterTools"
          end

          b.aggregate "SessionTools" do
            description "MCP tools for session management: create or load domain sessions"
            command "CreateSession" do
              attribute :name, String
            end
            command "LoadDomain" do
              attribute :path, String
            end
          end

          b.aggregate "AggregateTools" do
            description "MCP tools for building domain structure: aggregates, commands, value objects"
            command "AddAggregate" do
              attribute :name, String
            end
            command "AddAttribute" do
              attribute :aggregate, String
              attribute :name, String
            end
            command "AddCommand" do
              attribute :aggregate, String
              attribute :name, String
            end
          end

          b.aggregate "AggregateLifecycleTools" do
            description "MCP tools for lifecycle, transitions, computed attributes, and removal"
            command "AddLifecycle" do
              attribute :aggregate, String
              attribute :field, String
            end
            command "AddTransition" do
              attribute :aggregate, String
            end
          end

          b.aggregate "InspectTools" do
            description "MCP tools for read-only domain introspection"
            command "DescribeDomain"
            command "ListAggregates"
            command "PreviewCode"
          end

          b.aggregate "BuildTools" do
            description "MCP tools for domain lifecycle: validate, build gem, save DSL, serve"
            command "Validate"
            command "BuildGem"
            command "SaveDsl"
          end

          b.aggregate "PlayTools" do
            description "MCP tools for play mode: execute commands against in-memory runtime"
            command "EnterPlayMode"
            command "ExecuteCommand" do
              attribute :command_name, String
            end
            command "ShowHistory"
          end

          b.aggregate "ServiceTools" do
            description "MCP tool for adding cross-aggregate domain services"
            command "AddService" do
              attribute :name, String
            end
          end

          b.aggregate "GovernanceTools" do
            description "MCP wrapper around GovernanceGuard for governance checks"
            command "GovernanceCheck"
          end

          b.aggregate "DomainServer" do
            description "Generates MCP server from a compiled domain with command/query/repo tools"
            command "Run"
          end

          b.aggregate "GovernanceGuard" do
            description "Entry-point agnostic governance checker against world concerns"
            command "Check"
          end

          b.aggregate "McpConnection" do
            description "MCP protocol connection adapter bridging listens_to declarations to DomainServer"
            command "Run"
          end

          b.aggregate "TypeResolver" do
            description "Converts type strings to Ruby types or descriptor hashes"
            command "Resolve" do
              attribute :type_string, String
            end
          end

          b.aggregate "LlmClient" do
            description "Minimal net/http client for Anthropic Messages API with tool_use"
            command "GenerateDomain" do
              attribute :description, String
            end
          end

          b.aggregate "DomainBuilder" do
            description "Walks LLM JSON and replays through Workshop API to build a validated domain"
            command "Build"
          end

          b.aggregate "DomainGeneration" do
            description "System prompt with few-shot examples for LLM domain generation"
            command "GetPrompt"
          end

          Chapters.define_paragraphs(AI, b)
        }.build
      end
    end
  end
end
