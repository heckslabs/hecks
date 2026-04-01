module Hecks
  module MCP
    # Hecks::MCP::PlayTools
    #
    # MCP tools for play mode -- an interactive playground where AI agents can
    # execute domain commands against an in-memory runtime and observe the results.
    #
    # Registered tools:
    #   - +enter_play_mode+   -- switch the session to play mode
    #   - +exit_play_mode+    -- switch back to build mode
    #   - +execute_command+   -- run a named command with attributes
    #   - +list_commands+     -- show all available commands
    #   - +show_history+      -- display the event timeline
    #   - +reset_playground+  -- clear all events and state
    #
    module PlayTools
      # Registers all play mode tools on the given MCP server.
      #
      # @param server [MCP::Server] the MCP server instance
      # @param ctx [Hecks::McpServer] shared context with session, capture_output
      # @return [void]
      def self.register(server, ctx)
        server.define_tool(
          name: "enter_play_mode",
          description: "Switch to play mode — try out actions",
          input_schema: { type: "object", properties: {} }
        ) do |_|
          ctx.ensure_session!
          ctx.capture_output { ctx.workshop.play! }
        end

        server.define_tool(
          name: "exit_play_mode",
          description: "Switch back to build mode",
          input_schema: { type: "object", properties: {} }
        ) do |_|
          ctx.ensure_session!
          ctx.capture_output { ctx.workshop.sketch! }
        end

        server.define_tool(
          name: "execute_command",
          description: "Execute an action (e.g. CreatePizza)",
          input_schema: {
            type: "object",
            properties: {
              command: { type: "string", description: "Action name" },
              attrs: { type: "object", description: "Attributes" }
            },
            required: ["command"]
          }
        ) do |args|
          ctx.ensure_session!
          ctx.workshop.play! unless ctx.workshop.play?
          attrs = (args["attrs"] || {}).transform_keys(&:to_sym)
          ctx.capture_output { ctx.workshop.execute(args["command"], **attrs) }
        end

        server.define_tool(
          name: "list_commands",
          description: "List available actions in play mode",
          input_schema: { type: "object", properties: {} }
        ) do |_|
          ctx.ensure_session!
          ctx.workshop.commands.join("\n")
        end

        server.define_tool(
          name: "show_history",
          description: "Show the event timeline",
          input_schema: { type: "object", properties: {} }
        ) do |_|
          ctx.ensure_session!
          ctx.capture_output { ctx.workshop.history }
        end

        server.define_tool(
          name: "reset_playground",
          description: "Clear events and start over",
          input_schema: { type: "object", properties: {} }
        ) do |_|
          ctx.ensure_session!
          ctx.workshop.reset!
          "playground reset"
        end

        server.define_tool(
          name: "extend",
          description: "Apply an extension to the live runtime (e.g. :logging, :sqlite, :tenancy)",
          input_schema: {
            type: "object",
            properties: {
              name: { type: "string", description: "Extension name (e.g. logging, sqlite, tenancy)" }
            },
            required: ["name"]
          }
        ) do |args|
          ctx.ensure_session!
          ctx.capture_output { ctx.workshop.extend(args["name"].to_sym) }
        end
      end
    end
  end
end
