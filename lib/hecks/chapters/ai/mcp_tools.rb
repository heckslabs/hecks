# Hecks::Chapters::AI::McpToolsParagraph
#
# Paragraph defining MCP tool aggregates: session, aggregate, lifecycle,
# inspect, build, play, service, governance, and domain-server tool mixins.
#
#   Hecks::Chapters.define_paragraphs(Hecks::Chapters::AI, builder)
#
module Hecks
  module Chapters
    module AI
      module McpToolsParagraph
        def self.define(b)
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
            command "RunGovernanceCheck"
          end

          b.aggregate "CommandTools" do
            description "DomainServer mixin: registers MCP tools for domain commands"
            command "RegisterCommandTools"
          end

          b.aggregate "QueryTools" do
            description "DomainServer mixin: registers MCP tools for domain queries"
            command "RegisterQueryTools"
          end

          b.aggregate "RepositoryTools" do
            description "DomainServer mixin: registers Find/All/Count tools per aggregate"
            command "RegisterRepositoryTools"
          end
        end
      end
    end
  end
end
