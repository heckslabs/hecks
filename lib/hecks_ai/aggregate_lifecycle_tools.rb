module Hecks
  module MCP
    # Hecks::MCP::AggregateLifecycleTools
    #
    # MCP tools for lifecycle, transitions, computed attributes, and aggregate
    # removal. Split from AggregateTools to keep file sizes manageable.
    #
    # Registered tools:
    #   - +add_lifecycle+     -- add a state machine to an aggregate
    #   - +add_transition+    -- add a lifecycle transition
    #   - +add_computed+      -- add a computed (derived) attribute
    #   - +remove_aggregate+  -- remove an aggregate from the domain
    #
    module AggregateLifecycleTools
      # Registers lifecycle, transition, computed, and removal tools.
      #
      # @param server [MCP::Server] the MCP server instance
      # @param ctx [Hecks::McpServer] shared context with session, capture_output
      # @return [void]
      def self.register(server, ctx)
        server.define_tool(
          name: "add_lifecycle",
          description: "Add a state machine (e.g. status: draft -> published -> archived)",
          input_schema: {
            type: "object",
            properties: {
              aggregate: { type: "string" },
              field: { type: "string", description: "Attribute that holds the state (e.g. status)" },
              default: { type: "string", description: "Initial state (e.g. draft)" }
            },
            required: ["aggregate", "field", "default"]
          }
        ) do |args|
          ctx.ensure_session!
          ctx.capture_output do
            handle = ctx.workshop.aggregate(args["aggregate"])
            handle.lifecycle(args["field"].to_sym, default: args["default"])
          end
        end

        server.define_tool(
          name: "add_transition",
          description: "Add a lifecycle transition (e.g. PublishPost -> published)",
          input_schema: {
            type: "object",
            properties: {
              aggregate: { type: "string" },
              command: { type: "string", description: "Command name (e.g. PublishPost)" },
              target: { type: "string", description: "Target state (e.g. published)" }
            },
            required: ["aggregate", "command", "target"]
          }
        ) do |args|
          ctx.ensure_session!
          ctx.capture_output do
            handle = ctx.workshop.aggregate(args["aggregate"])
            handle.transition(args["command"] => args["target"])
          end
        end

        server.define_tool(
          name: "add_computed",
          description: "Add a derived attribute computed from other attributes (e.g. lot_size = area / 43560)",
          input_schema: {
            type: "object",
            properties: {
              aggregate: { type: "string", description: "Aggregate name (PascalCase)" },
              name: { type: "string", description: "Computed attribute name (snake_case)" },
              formula: { type: "string", description: "Ruby expression body (e.g. 'area / 43560.0')" }
            },
            required: ["aggregate", "name", "formula"]
          }
        ) do |args|
          ctx.ensure_session!
          ctx.capture_output do
            handle = ctx.workshop.aggregate(args["aggregate"])
            block = eval("proc { #{args["formula"]} }")
            handle.computed(args["name"].to_sym, &block)
          end
        end

        server.define_tool(
          name: "remove_aggregate",
          description: "Remove a thing from the domain",
          input_schema: { type: "object", properties: { name: { type: "string" } }, required: ["name"] }
        ) do |args|
          ctx.ensure_session!
          ctx.capture_output { ctx.workshop.remove(args["name"]) }
        end
      end
    end
  end
end
