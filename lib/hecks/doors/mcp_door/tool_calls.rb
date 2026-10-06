require_relative "../../../hecks"

module Hecks
  module Doors
    module McpDoor
      # Answers one `tools/call`: the tool a name stands for, run against the booted domain the
      # call names. A domain refusal is already `{ok: false, ...}` from `Storehouse`.
      module ToolCalls
        # The method that answers each tool.
        HANDLERS = {
          "dispatch"  => :dispatch_tool,
          "query"     => :query_tool,
          "events"    => :events_tool,
          "state"     => :state_tool,
          "catalog"   => :catalog_tool,
          "describe"  => :describe_tool,
          "validate"  => :validate_tool,
          "domains"   => :domains_tool,
          "history"   => :history_tool,
          "behaviors" => :behaviors_tool,
          "follow"    => :follow_tool
        }.freeze

        module_function

        # Runs the tool `name` with `args`, so the shared `rescue` catches every tool's escape once.
        #
        # @param name [String] the tool's name
        # @param args [Hash{String => Object}] the call's arguments
        # @return [Hash{Symbol => Object}] the tool's answer, or `{ok: false, error: ...}`
        def call(name, args)
          handler = HANDLERS[name]
          return unknown(name) unless handler

          public_send(handler, args)
        rescue StandardError => e
          # A defect, not a refusal: reaching here means a bad domain path or an
          # argument shape `Doors::JsonDoor` could not symbolize.
          { ok: false, error: "#{e.class}: #{e.message}" }
        end

        # The refusal for a tool the door does not have.
        def unknown(name)
          { ok: false, error: "no such tool: #{name.inspect} — known: #{HANDLERS.keys.join(", ")}" }
        end

        # A question, once the scope has admitted its arguments.
        def query_tool(args)
          McpDoor.scope.admit_arguments!(args["args"])
          Storehouse.query(runtime: McpDoor.boot(args["domain"]), question: args["question"],
                           summary: args["summary"], args: args["args"] || {}, source: args["source"],
                           role: args["role"], actor_id: args["actor_id"])
        end

        # A single command or a batch, once the scope has admitted every command in it.
        def dispatch_tool(args)
          runtime = McpDoor.boot(args["domain"])
          return dispatch_steps(runtime, args) if args["steps"]

          McpDoor.scope.admit_command!(runtime, args["command"], args["args"])
          Storehouse.dispatch(runtime: runtime, command: args["command"], summary: args["summary"],
                              args: args["args"] || {}, source: args["source"],
                              dry_run: args["dry_run"] == true, role: args["role"], actor_id: args["actor_id"])
        end

        # Several commands in one call.
        def dispatch_steps(runtime, args)
          McpDoor.scope.admit_steps!(runtime, args["steps"])
          Storehouse.dispatch_batch(runtime: runtime, steps: args["steps"], summary: args["summary"],
                                    source: args["source"], role: args["role"], actor_id: args["actor_id"])
        end

        def events_tool(args)
          Storehouse.events(runtime: McpDoor.boot(args["domain"]), aggregate: args["aggregate"], id: args["id"],
                            limit: args["limit"])
        end

        def state_tool(args)
          Storehouse.state(runtime: McpDoor.boot(args["domain"]), aggregate: args["aggregate"],
                           summary: args["summary"], id: args["id"])
        end

        def catalog_tool(args)
          Storehouse.catalog(runtime: McpDoor.boot(args["domain"]))
        end

        def describe_tool(args)
          Storehouse.describe(runtime: McpDoor.boot(args["domain"]), aggregate: args["aggregate"])
        end

        def validate_tool(args)
          Storehouse.validate(domain: McpDoor.scope.admit_domain!(args["domain"]), deep: args["deep"] == true)
        end

        def domains_tool(args)
          Storehouse.domains(under: args["under"] || "examples")
        end

        def history_tool(args)
          Storehouse.history(runtime: McpDoor.boot(args["domain"]))
        end

        def behaviors_tool(args)
          Storehouse.behaviors(target: args["target"])
        end

        def follow_tool(args)
          Storehouse.follow(runtime: McpDoor.boot(args["domain"]), limit: args["limit"] || 20)
        end
      end
    end
  end
end
