module Hecks
  module MCP
    # Hecks::MCP::ServiceTools
    #
    # MCP tool for adding domain services -- cross-aggregate operations that
    # orchestrate multiple commands. Services are domain-level (not scoped to
    # a single aggregate), so they live in their own tool module.
    #
    # Registered tools:
    #   - +add_service+ -- add a domain service with attributes and coordinated aggregates
    #
    #   # Via MCP:
    #   add_service(name: "TransferMoney", attributes: [{name: "amount", type: "Float"}])
    #
    module ServiceTools
      # Registers the add_service tool on the given MCP server.
      #
      # @param server [MCP::Server] the MCP server instance
      # @param ctx [Hecks::McpServer] shared context with session, capture_output
      # @return [void]
      def self.register(server, ctx)
        server.define_tool(
          name: "add_service",
          description: "Add a domain service that coordinates commands across aggregates (e.g. TransferMoney)",
          input_schema: {
            type: "object",
            properties: {
              name: { type: "string", description: "Service name (PascalCase, e.g. TransferMoney)" },
              attributes: {
                type: "array",
                items: {
                  type: "object",
                  properties: {
                    name: { type: "string" },
                    type: { type: "string" }
                  }
                },
                description: "Input attributes for the service"
              },
              coordinates: {
                type: "array",
                items: { type: "string" },
                description: "Aggregate names this service coordinates"
              }
            },
            required: ["name"]
          }
        ) do |args|
          ctx.ensure_session!
          ctx.capture_output do
            ctx.workshop.service(args["name"]) do
              (args["attributes"] || []).each do |attr|
                attribute attr["name"].to_sym, ctx.resolve_type(attr["type"] || "String")
              end
              coordinates(*(args["coordinates"] || []))
            end
          end
        end
      end
    end
  end
end
