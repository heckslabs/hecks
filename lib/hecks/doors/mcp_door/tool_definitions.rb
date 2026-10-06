require_relative "tool_definitions/calling"
require_relative "tool_definitions/reading"
require_relative "tool_definitions/auditing"

module Hecks
  module Doors
    module McpDoor
      # The tools the MCP door answers: their names, descriptions and input schemas, in the order
      # `tools/list` shows them.
      module ToolDefinitions
        TOOLS = (Calling::LIST + Reading::LIST + Auditing::LIST).freeze
      end
    end
  end
end
