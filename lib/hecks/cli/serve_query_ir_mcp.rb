# frozen_string_literal: true

require_relative "../mcp_stdio_guard"

module Hecks
  module CLI
    # The command behind `hecks serve_query_ir_mcp` and `hecks serve_query_ir_mcp`: an MCP server
    # exposing `Hecks::QueryIR`'s queries as tools, over newline-delimited JSON-RPC on stdio.
    #
    # Stdio only and unauthenticated (ADR 0062); the protocol lives in `Hecks::QueryIrMcp` and the
    # query logic in `Hecks::QueryIR`. The stdio guard runs before the runtime loads, so a refused
    # transport never boots anything.
    module ServeQueryIrMcp
      module_function

      # Enforces stdio, then serves until stdin closes.
      #
      # @param argv [Array<String>] the arguments the server was started with
      # @return [void]
      # @raise [SystemExit] when the guard refuses the transport
      def call(argv)
        Hecks::McpStdioGuard.enforce_stdio!(server: "hecks-query-ir")

        require_relative "../../hecks"
        require_relative "../query_ir_mcp"
        Hecks::QueryIrMcp.start(argv: argv)
      end
    end
  end
end
