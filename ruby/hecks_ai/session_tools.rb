module Hecks
  module MCP
    # Hecks::MCP::SessionTools
    #
    # MCP tools for session management. A session is the entry point for
    # domain modeling -- it must be created or loaded before any other tools
    # can be used. These tools set +ctx.workshop+ on the shared McpServer context.
    #
    # Registered tools:
    #   - +create_session+ -- start a new blank domain modeling session
    #   - +load_domain+    -- load an existing domain.rb file
    #
    module SessionTools
      # Registers session management tools on the given MCP server.
      #
      # @param server [MCP::Server] the MCP server instance
      # @param ctx [Hecks::McpServer] shared context; +ctx.workshop+ set on invoke
      # @return [void]
      def self.register(server, ctx)
        server.define_tool(
          name: "create_session",
          description: "Create a new domain modeling session",
          input_schema: { type: "object", properties: { name: { type: "string", description: "Domain name (e.g. Pizzas)" } }, required: ["name"] }
        ) do |args|
          ctx.workshop = Hecks.workshop(args["name"])
          "#{args["name"]} session created"
        end

        server.define_tool(
          name: "load_domain",
          description: "Load an existing domain.rb file",
          input_schema: { type: "object", properties: { path: { type: "string", description: "Path to domain.rb" } }, required: ["path"] }
        ) do |args|
          ctx.capture_output do
            Kernel.load(args["path"])
            domain = Hecks.last_domain
            ctx.workshop = Hecks.workshop(domain.name)
            domain.aggregates.each do |agg|
              handle = ctx.workshop.aggregate(agg.name)
              agg.attributes.each { |a| handle.attr(a.name, a.type) }
            end
            puts "#{domain.name} loaded (#{domain.aggregates.map(&:name).join(', ')})"
          end
        end
      end
    end
  end
end
