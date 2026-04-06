# Hecks::Chapters::Ai
#
# Self-describing Bluebook chapter for the hecks_ai module. Models the AI
# subsystem -- MCP servers, IDE, LLM-driven domain generation, and governance
# checking -- as a Hecks domain using the same DSL it provides to users.
#
# Aggregates mirror the real module structure:
#   McpServer      — workshop-mode MCP server with tool groups
#   DomainServer   — compiled-domain MCP server (command/query/repository)
#   IdeServer      — browser-based IDE with Claude integration
#   LlmClient      — Anthropic Messages API client for domain generation
#   GovernanceGuard — world-concern validation engine
#
#   Hecks::Chapters::Ai.definition
#   # => #<Hecks::DomainModel::Structure::Domain name="Ai" ...>
#
module Hecks
  module Chapters
    module Ai
      def self.definition
        @definition ||= DSL::DomainBuilder.new("Ai").tap { |b|
          b.instance_eval do
            aggregate "McpServer" do
              attribute :name, String
              attribute :version, String

              command "RegisterToolGroup" do
                attribute :group_name, String
              end

              command "Run" do
                attribute :transport, String
              end

              command "EnsureSession" do
                attribute :session_id, String
              end

              command "ResolveType" do
                attribute :type_str, String
              end
            end

            aggregate "DomainServer" do
              attribute :domain_name, String

              command "BootAndRegister" do
                attribute :domain_name, String
              end

              command "RegisterCommandTools" do
                attribute :domain_name, String
              end

              command "RegisterQueryTools" do
                attribute :domain_name, String
              end

              command "RegisterRepositoryTools" do
                attribute :domain_name, String
              end
            end

            aggregate "IdeServer" do
              attribute :project_dir, String
              attribute :port, Integer

              command "StartServer" do
                attribute :port, Integer
              end

              command "SendPrompt" do
                attribute :prompt, String
              end

              command "OpenWorkshop" do
                attribute :bluebook_path, String
              end

              command "ExecuteWorkshopCommand" do
                attribute :input, String
              end

              command "TakeScreenshot" do
                attribute :path, String
              end

              command "RunShellCommand" do
                attribute :command, String
              end
            end

            aggregate "LlmClient" do
              attribute :api_key, String
              attribute :model, String

              command "GenerateDomain" do
                attribute :description, String
              end
            end

            aggregate "DomainBuilder" do
              attribute :domain_name, String

              command "BuildFromJson" do
                attribute :domain_name, String
              end
            end

            aggregate "GovernanceGuard" do
              attribute :domain_name, String

              command "CheckGovernance" do
                attribute :domain_name, String
              end
            end

            aggregate "DomainSerializer" do
              attribute :domain_name, String

              command "Serialize" do
                attribute :domain_name, String
              end
            end

            aggregate "McpConnection" do
              attribute :domain_name, String
              attribute :transport, String

              command "Connect" do
                attribute :domain_name, String
                attribute :transport, String
              end
            end
          end
        }.build
      end
    end
  end
end
