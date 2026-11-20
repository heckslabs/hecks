# frozen_string_literal: true

require_relative "../mcp_stdio_guard"

module Hecks
  # The stdio entry of the MCP server over `Hecks::QueryIR`'s queries, behind the project's
  # `.mcp.json`.
  #
  # Stdio only and unauthenticated (ADR 0062). The stdio guard runs before the runtime loads, so a
  # refused transport never boots anything, and the runtime itself loads on the first tool call, so
  # an idle server stays small.
  module QueryIrMcp
    # Enforces stdio, then serves until stdin closes.
    #
    # @param argv [Array<String>] the arguments the server was started with
    # @return [void]
    # @raise [SystemExit] when the guard refuses the transport
    def self.serve_stdio(argv)
      McpStdioGuard.enforce_stdio!(server: "hecks-query-ir")
      require_relative "../query_ir_mcp"
      start(argv: argv)
    end
  end
end
