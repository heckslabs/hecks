module Hecks
  module MCP
    # Hecks::MCP::AggregateTools
    #
    # MCP tools for building domain structure: add/remove aggregates, commands,
    # value objects, entities, validations, policies, lifecycle, and transitions.
    # Each tool delegates to the Session's AggregateHandle API and captures
    # the terse feedback it prints to stdout.
    #
    # Registered tools:
    #   - +add_aggregate+     -- create a new aggregate root with optional attributes
    #   - +add_attribute+     -- add an attribute to an existing aggregate
    #   - +add_command+       -- add a command (action) to an aggregate
    #   - +add_value_object+  -- add an embedded value object to an aggregate
    #   - +add_entity+        -- add a sub-entity with identity to an aggregate
    #   - +add_validation+    -- add a validation rule to an aggregate field
    #   - +add_policy+        -- add a reactive policy (event -> trigger)
    #   - +add_lifecycle+     -- see AggregateLifecycleTools
    #   - +add_transition+    -- see AggregateLifecycleTools
    #   - +add_computed+      -- see AggregateLifecycleTools
    #   - +remove_aggregate+  -- see AggregateLifecycleTools
    #
    module AggregateTools
      # Registers all aggregate structure tools on the given MCP server.
      #
      # @param server [MCP::Server] the MCP server instance
      # @param ctx [Hecks::McpServer] shared context with session, capture_output
      # @return [void]
      def self.register(server, ctx)
        server.define_tool(
          name: "add_aggregate",
          description: "Add a new thing to the domain (e.g. Pizza, Order)",
          input_schema: {
            type: "object",
            properties: {
              name: { type: "string", description: "Name (PascalCase)" },
              attributes: { type: "array", items: { type: "object", properties: { name: { type: "string" }, type: { type: "string" } } } }
            },
            required: ["name"]
          }
        ) do |args|
          ctx.ensure_session!
          ctx.capture_output do
            handle = ctx.workshop.aggregate(args["name"])
            (args["attributes"] || []).each do |attr|
              if ctx.reference_type?(attr["type"])
                handle.reference_to(ctx.reference_target(attr["type"]))
              else
                handle.attr(attr["name"].to_sym, ctx.resolve_type(attr["type"]))
              end
            end
          end
        end

        server.define_tool(
          name: "add_attribute",
          description: "Add an attribute to an aggregate (e.g. title String, post_id reference_to(Post))",
          input_schema: {
            type: "object",
            properties: {
              aggregate: { type: "string" },
              name: { type: "string" },
              type: { type: "string", description: "String, Integer, Float, reference_to(Name), list_of(Name)" }
            },
            required: ["aggregate", "name"]
          }
        ) do |args|
          ctx.ensure_session!
          ctx.capture_output do
            handle = ctx.workshop.aggregate(args["aggregate"])
            type_str = args["type"] || "String"
            if ctx.reference_type?(type_str)
              handle.reference_to(ctx.reference_target(type_str))
            else
              handle.attr(args["name"].to_sym, ctx.resolve_type(type_str))
            end
          end
        end

        server.define_tool(
          name: "add_command",
          description: "Add an action (e.g. CreatePizza, PlaceOrder)",
          input_schema: {
            type: "object",
            properties: {
              aggregate: { type: "string" },
              name: { type: "string", description: "Verb + thing (e.g. CreatePizza)" },
              attributes: { type: "array", items: { type: "object", properties: { name: { type: "string" }, type: { type: "string" } } } }
            },
            required: ["aggregate", "name"]
          }
        ) do |args|
          ctx.ensure_session!
          ctx.capture_output do
            handle = ctx.workshop.aggregate(args["aggregate"])
            attrs = args["attributes"] || []
            plain_attrs = attrs.reject { |a| ctx.reference_type?(a["type"]) }
            ref_attrs = attrs.select { |a| ctx.reference_type?(a["type"]) }
            resolved = plain_attrs.map { |a| [a["name"].to_sym, ctx.resolve_type(a["type"])] }
            ref_targets = ref_attrs.map { |a| ctx.reference_target(a["type"]) }
            handle.command(args["name"]) do
              resolved.each { |name, type| attribute name, type }
              ref_targets.each { |target| reference_to target }
            end
          end
        end

        server.define_tool(
          name: "add_value_object",
          description: "Add an embedded detail (e.g. Topping on Pizza)",
          input_schema: {
            type: "object",
            properties: {
              aggregate: { type: "string" },
              name: { type: "string" },
              attributes: { type: "array", items: { type: "object", properties: { name: { type: "string" }, type: { type: "string" } } } }
            },
            required: ["aggregate", "name"]
          }
        ) do |args|
          ctx.ensure_session!
          ctx.capture_output do
            handle = ctx.workshop.aggregate(args["aggregate"])
            resolved = (args["attributes"] || []).map { |a| [a["name"].to_sym, ctx.resolve_type(a["type"])] }
            handle.value_object(args["name"]) do
              resolved.each { |name, type| attribute name, type }
            end
          end
        end

        server.define_tool(
          name: "add_entity",
          description: "Add a sub-entity with identity (e.g. LedgerEntry on Account)",
          input_schema: {
            type: "object",
            properties: {
              aggregate: { type: "string" },
              name: { type: "string" },
              attributes: { type: "array", items: { type: "object", properties: { name: { type: "string" }, type: { type: "string" } } } }
            },
            required: ["aggregate", "name"]
          }
        ) do |args|
          ctx.ensure_session!
          ctx.capture_output do
            handle = ctx.workshop.aggregate(args["aggregate"])
            resolved = (args["attributes"] || []).map { |a| [a["name"].to_sym, ctx.resolve_type(a["type"])] }
            handle.entity(args["name"]) do
              resolved.each { |name, type| attribute name, type }
            end
          end
        end

        server.define_tool(
          name: "add_validation",
          description: "Add a requirement (e.g. name must be present)",
          input_schema: {
            type: "object",
            properties: { aggregate: { type: "string" }, field: { type: "string" }, presence: { type: "boolean" } },
            required: ["aggregate", "field"]
          }
        ) do |args|
          ctx.ensure_session!
          ctx.capture_output do
            handle = ctx.workshop.aggregate(args["aggregate"])
            rules = {}
            rules[:presence] = true if args["presence"]
            handle.validation(args["field"].to_sym, rules)
          end
        end

        server.define_tool(
          name: "add_policy",
          description: "Add a reaction — when event happens, trigger action",
          input_schema: {
            type: "object",
            properties: {
              aggregate: { type: "string" }, name: { type: "string" },
              on_event: { type: "string" }, trigger: { type: "string" }
            },
            required: ["aggregate", "name", "on_event", "trigger"]
          }
        ) do |args|
          ctx.ensure_session!
          ctx.capture_output do
            handle = ctx.workshop.aggregate(args["aggregate"])
            evt, trig = args["on_event"], args["trigger"]
            handle.policy(args["name"]) { on evt; trigger trig }
          end
        end

        AggregateLifecycleTools.register(server, ctx)
      end
    end
  end
end
