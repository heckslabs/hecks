module Hecks
  module MCP
    # Hecks::MCP::BuildTools
    #
    # MCP tools for domain lifecycle operations: validate, build gem, save DSL,
    # and serve the domain as HTTP. All output is captured from the Session
    # methods so Claude sees the same feedback the REPL user would.
    #
    # Registered tools:
    #   - +validate+      -- check the domain for structural errors
    #   - +build_gem+     -- generate a Ruby gem from the domain model
    #   - +save_dsl+      -- persist the domain DSL to a .rb file
    #   - +serve_domain+  -- start an HTTP server exposing the domain
    #
    module BuildTools
      # Registers all build/lifecycle tools on the given MCP server.
      #
      # @param server [MCP::Server] the MCP server instance
      # @param ctx [Hecks::McpServer] shared context with session, capture_output
      # @return [void]
      def self.register(server, ctx)
        server.define_tool(
          name: "validate",
          description: "Check the domain for errors",
          input_schema: { type: "object", properties: {} }
        ) do |_|
          ctx.ensure_session!
          ctx.capture_output { ctx.workshop.validate }
        end

        server.define_tool(
          name: "build_gem",
          description: "Generate the domain gem",
          input_schema: { type: "object", properties: { output_dir: { type: "string" } } }
        ) do |args|
          ctx.ensure_session!
          ctx.capture_output { ctx.workshop.build(output_dir: args["output_dir"] || ".") }
        end

        server.define_tool(
          name: "save_dsl",
          description: "Save domain DSL to a file",
          input_schema: { type: "object", properties: { path: { type: "string" } } }
        ) do |args|
          ctx.ensure_session!
          ctx.capture_output { ctx.workshop.save(args["path"] || "Bluebook") }
        end

        server.define_tool(
          name: "serve_domain",
          description: "Serve the domain as HTTP REST API with SSE events",
          input_schema: { type: "object", properties: { gate: { type: "integer", description: "Port (default 9292)" } } }
        ) do |args|
          ctx.ensure_session!
          domain = ctx.workshop.send(:to_domain)
          require "hecks_serve"
          port = args["port"] || 9292
          Thread.new { Hecks::HTTP::DomainServer.new(domain, gate: port).run }
          "Serving domain on http://localhost:#{port}"
        end

        server.define_tool(
          name: "promote",
          description: "Promote an aggregate into its own standalone domain",
          input_schema: {
            type: "object",
            properties: {
              aggregate: { type: "string", description: "Aggregate name to promote (e.g. Comments)" }
            },
            required: ["aggregate"]
          }
        ) do |args|
          ctx.ensure_session!
          ctx.capture_output { ctx.workshop.promote(args["aggregate"]) }
        end
      end
    end
  end
end
