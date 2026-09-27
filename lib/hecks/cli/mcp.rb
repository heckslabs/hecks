require_relative "../mcp_stdio_guard"

module Hecks
  module CLI
    # The command behind `bin/hecks_mcp_door` and `hecks mcp`: the MCP door onto the
    # storehouse bus, over stdio only.
    #
    # This file loads nothing but `McpStdioGuard`, so the transport check runs before
    # the framework does. The door itself is `McpDoor`, required only once the check
    # passes.
    module Mcp
      # The server name the guard's refusals and warnings carry.
      SERVER = "hecks-mcp-door".freeze

      module_function

      # Refuses any transport but stdio, then serves JSON-RPC requests from stdin
      # until it closes.
      #
      # @param argv [Array<String>] the arguments after the command; only `--stdio`
      #   is accepted
      # @return [void]
      # @raise [SystemExit] with `McpStdioGuard::EXIT_STATUS` when the process is not
      #   set up for stdio
      def call(argv)
        McpStdioGuard.enforce_stdio!(server: SERVER, argv: argv)
        require_relative "mcp_door"
        McpDoor.serve
      end
    end
  end
end
