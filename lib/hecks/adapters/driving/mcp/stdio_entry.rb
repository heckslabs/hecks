# frozen_string_literal: true

require_relative "../../../mcp_stdio_guard"

module Hecks
  module Adapters
    module Driving
      # The stdio entry of the MCP server onto the storehouse bus, behind `hecks mcp` and the
      # project's `.mcp.json`.
      #
      # This file loads nothing but `McpStdioGuard`, so the transport check runs before the
      # framework does.
      module Mcp
        # The server name the guard's refusals and warnings carry.
        SERVER = "hecks-mcp"

        # Refuses any transport but stdio, then serves JSON-RPC requests from stdin until it
        # closes.
        #
        # @param argv [Array<String>] the arguments after the command; only `--stdio` is accepted
        # @return [void]
        # @raise [SystemExit] with `McpStdioGuard::EXIT_STATUS` when the process is not set up for
        #   stdio
        def self.serve_stdio(argv)
          McpStdioGuard.enforce_stdio!(server: SERVER, argv: argv)
          require_relative "../mcp"
          serve
        end
      end
    end
  end
end
