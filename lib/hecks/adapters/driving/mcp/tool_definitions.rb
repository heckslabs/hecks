require_relative "../mcp/tool_definitions/calling"
require_relative "../mcp/tool_definitions/reading"
require_relative "../mcp/tool_definitions/auditing"
require_relative "../mcp/tool_definitions/running"

module Hecks
  module Adapters
    module Driving
      module Mcp
        # The tools the MCP server answers: their names, descriptions and input schemas, in the
        # order
        # `tools/list` shows them.
        module ToolDefinitions
          TOOLS = (Calling::LIST + Running::LIST + Reading::LIST + Auditing::LIST).freeze
        end
      end
    end
  end
end
