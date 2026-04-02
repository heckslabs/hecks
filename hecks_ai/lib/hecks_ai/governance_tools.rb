# Hecks::MCP::GovernanceTools
#
# Thin MCP wrapper around Hecks::GovernanceGuard. Extracts the domain
# from the workshop context and delegates to the general-purpose guard.
#
# Registered tools:
#   - +governance_check+ -- run governance checks against world concerns
#
#   # via MCP
#   { "tool": "governance_check" }
#   # => { "passed": false, "violations": [...], "suggestions": [...] }
#
module Hecks
  module MCP
    module GovernanceTools
      # Registers governance tools on the given MCP server.
      #
      # @param server [MCP::Server] the MCP server instance
      # @param ctx [Hecks::McpServer] shared context with workshop access
      # @return [void]
      def self.register(server, ctx)
        server.define_tool(
          name: "governance_check",
          description: "Run governance checks against declared world concerns (transparency, consent, privacy, security). Returns violations and actionable suggestions.",
          input_schema: { type: "object", properties: {} }
        ) do |_|
          ctx.ensure_session!
          domain = ctx.workshop.to_domain
          guard = Hecks::GovernanceGuard.new(domain)
          result = guard.check
          JSON.generate(result.to_h)
        end
      end
    end
  end
end
