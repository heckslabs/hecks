# = HecksAi
#
# MCP server and AI tools for Hecks. Provides aggregate building,
# domain inspection, play mode, and build tools via MCP protocol.
# Also includes LLM-driven domain generation (HEC-102).
#
module Hecks
  module AI
    autoload :McpServer,        "hecks_ai/mcp_server"
    autoload :AggregateTools,   "hecks_ai/aggregate_tools"
    autoload :BuildTools,       "hecks_ai/build_tools"
    autoload :InspectTools,     "hecks_ai/inspect_tools"
    autoload :PlayTools,        "hecks_ai/play_tools"
    autoload :SessionTools,     "hecks_ai/session_tools"
    autoload :DomainSerializer, "hecks_ai/domain_serializer"
    autoload :DomainServer,     "hecks_ai/domain_server"
    autoload :Connection,       "hecks_ai/connection"
    autoload :TypeResolver,     "hecks_ai/type_resolver"
    autoload :LlmClient,        "hecks_ai/llm_client"
    autoload :DomainBuilder,    "hecks_ai/domain_builder"

    module Prompts
      autoload :DomainGeneration, "hecks_ai/prompts/domain_generation"
      autoload :DomainToolSchema, "hecks_ai/prompts/domain_tool_schema"
    end
  end
end
