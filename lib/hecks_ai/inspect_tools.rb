Hecks::Chapters.load_aggregates(
  Hecks::Chapters::AI::InspectParagraph,
  base_dir: __dir__
)

module Hecks
  module MCP
    # Hecks::MCP::InspectTools
    #
    # MCP tools for read-only domain introspection. These tools let AI agents
    # examine the current domain model without modifying it.
    #
    # Registered tools:
    #   - +describe_domain+  -- full structured JSON of the domain (aggregates,
    #     commands, queries, value objects, validations, policies, services)
    #   - +list_aggregates+  -- comma-separated list of aggregate names
    #   - +preview_code+     -- generated Ruby source code for an aggregate (or all)
    #   - +show_dsl+         -- the raw Hecks DSL source that defines the domain
    #
    # All tools require an active session (enforced via +ctx.ensure_session!+).
    #
    module InspectTools
      # Registers all domain inspection tools on the given MCP server.
      #
      # @param server [MCP::Server] the MCP server instance to register tools on
      # @param ctx [Hecks::McpServer] the shared context providing session access,
      #   +ensure_session!+, and +capture_output+ helpers
      # @return [void]
      def self.register(server, ctx)
        server.define_tool(
          name: "describe_domain",
          description: "Returns the complete domain model as structured JSON — aggregates, commands, queries, policies, validations, and their relationships. Use this as your first call to understand the domain.",
          input_schema: { type: "object", properties: {} }
        ) do |_|
          ctx.ensure_session!
          domain = ctx.workshop.to_domain
          JSON.generate(DomainSerializer.call(domain))
        end

        server.define_tool(
          name: "list_aggregates",
          description: "List all things in the domain",
          input_schema: { type: "object", properties: {} }
        ) do |_|
          ctx.ensure_session!
          ctx.workshop.aggregates.join(", ")
        end

        server.define_tool(
          name: "preview_code",
          description: "Show generated Ruby code",
          input_schema: { type: "object", properties: { aggregate: { type: "string" } } }
        ) do |args|
          ctx.ensure_session!
          ctx.capture_output { ctx.workshop.preview(args["aggregate"]) }
        end

        server.define_tool(
          name: "show_dsl",
          description: "Show the domain DSL source",
          input_schema: { type: "object", properties: {} }
        ) do |_|
          ctx.ensure_session!
          ctx.workshop.to_dsl
        end
      end
    end
  end
end
