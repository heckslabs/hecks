require "json"
require_relative "../../hecks"
require_relative "../cli/mcp"

module Hecks
  module Doors
    # The MCP door onto the storehouse bus: hand-rolled JSON-RPC over stdio, one
    # server per booted domain. All logic and the JSON shape answered with live in
    # `Storehouse`; this is plumbing only. A `role:`/`actor_id:` a caller sends is
    # asserted, not verified, unless Governance is attached.
    #
    # There is no authentication: `domain:` boots real Ruby confined to
    # `Storehouse::BOOT_ROOT`, so this is a code execution surface for anyone who
    # can write to stdin (ADR 0062). Spawning with `HECKS_DOOR_TOOLS=readers` and
    # `HECKS_DOOR_DOMAINS=<dir>[:<dir>...]` narrows a door to read-only tools and
    # named domains (`McpDoorScope`); this limits what one agent can reach and is
    # not itself authentication.
    module McpDoor
      PROTOCOL_VERSION = "2024-11-05".freeze

      SUMMARY_PROPERTY = {
        type:        "string",
        description: "One line: why this call is happening. Required — it is what makes the audit trail legible later."
      }.freeze

      DOMAIN_PROPERTY = {
        type:        "string",
        description: "The domain directory, containing a .hecksagon (e.g. \"examples/banking\"). The `domains` tool " \
                     "lists what's available."
      }.freeze

      ARGS_PROPERTY = {
        type:        "object",
        description: "The command/query's declared arguments, nested value-object literals included " \
                     "(e.g. {\"reference\":{\"value\":\"BUG#1\"}})."
      }.freeze

      SOURCE_PROPERTY = {
        type:        "string",
        enum:        Hecks::Storehouse::SOURCE_TAGS,
        description: "Optional: who is calling, for the audit log `follow` reads back."
      }.freeze

      ROLE_PROPERTY = {
        type:        "string",
        description: "Bind a caller identity for the call's duration, so a role-gated command's authorization is " \
                     "checked rather than merely documented. Required by `dispatch` for any command that declares a " \
                     "role — omitting it refuses the call rather than running it unchecked. Also required if " \
                     "`actor_id` is given."
      }.freeze

      ACTOR_ID_PROPERTY = {
        type:        "string",
        description: "Optional, alongside `role`: WHO holds that role — once the domain attaches Governance, checked " \
                     "against a real Governance::RoleAssignment instead of a bare string match. Requires `role`."
      }.freeze

      TOOLS = [
        {
          name:        "dispatch",
          description: "Issue a command against a booted domain — or, with `steps`, several in one call. `command` is " \
                       "the short or qualified verb name (the catalog/describe tools show what's available). Set " \
                       "`dry_run: true` to check whether it WOULD succeed without committing anything. Answers the " \
                       "record's id, its resulting state, and the events it announced — or a structured refusal, " \
                       "never a crash.",
          inputSchema: {
            type:       "object",
            properties: {
              domain:   DOMAIN_PROPERTY,
              command:  { type: "string", description: "The command's short or qualified name, e.g. \"open_account\". " \
                                                       "Ignored when `steps` is given." },
              args:     ARGS_PROPERTY,
              summary:  SUMMARY_PROPERTY,
              source:   SOURCE_PROPERTY,
              role:     ROLE_PROPERTY,
              actor_id: ACTOR_ID_PROPERTY,
              dry_run:  { type: "boolean", description: "Preview only — check the command would succeed, commit nothing. " \
                                                        "Ignored when `steps` is given." },
              steps:    {
                type:        "array",
                description: "Run several commands in one call, in order. Each item: {command, args}. When given, " \
                             "`command`/`args`/`dry_run` above are ignored.",
                items:       {
                  type:       "object",
                  properties: { command: { type: "string" }, args: ARGS_PROPERTY },
                  required:   %w[command]
                }
              }
            },
            required:   %w[domain summary]
          }
        },
        {
          name:        "query",
          description: "Ask a declared question of a booted domain. `question` is the short or qualified query name. " \
                       "Answers the row array the query itself declares.",
          inputSchema: {
            type:       "object",
            properties: {
              domain:   DOMAIN_PROPERTY,
              question: { type: "string", description: "The query's short or qualified name." },
              args:     ARGS_PROPERTY,
              summary:  SUMMARY_PROPERTY,
              source:   SOURCE_PROPERTY,
              role:     ROLE_PROPERTY,
              actor_id: ACTOR_ID_PROPERTY
            },
            required:   %w[domain question summary]
          }
        },
        {
          name:        "events",
          description: "What actually HAPPENED, with payloads, to one aggregate/record — events THIS DOOR witnessed " \
                       "(every real dispatch ever routed through it, sourced from its own audit log — not a full " \
                       "domain-wide event-sourcing replay). Distinct from `state` (what's stored now) and `history` " \
                       "(append-only operation snapshots, no payload). Narrow with `aggregate` and (requires " \
                       "`aggregate`) `id`; `limit` keeps only the most recent.",
          inputSchema: {
            type:       "object",
            properties: {
              domain:    DOMAIN_PROPERTY,
              aggregate: { type: "string", description: "Narrow to one aggregate, e.g. \"Account\"." },
              id:        { type: "string", description: "Narrow to one record's own events. Requires `aggregate`." },
              limit:     { type: "integer", description: "Keep only the most recent N events. Omit for all of them." }
            },
            required:   %w[domain]
          }
        },
        {
          name:        "state",
          description: "Read what an aggregate actually has stored, no verb involved. Pass `id` for one record; " \
                       "omit it to list every record the aggregate currently holds.",
          inputSchema: {
            type:       "object",
            properties: {
              domain:    DOMAIN_PROPERTY,
              aggregate: { type: "string", description: "The aggregate's name, e.g. \"Account\"." },
              id:        { type: "string", description: "A specific record's id. Omit to list every record." },
              summary:   SUMMARY_PROPERTY
            },
            required:   %w[domain aggregate summary]
          }
        },
        {
          name:        "catalog",
          description: "Zoom level one: every aggregate a domain declares, and every command/query name each " \
                       "answers to. No summary needed — this changes nothing and commits nothing to any log.",
          inputSchema: {
            type:       "object",
            properties: { domain: DOMAIN_PROPERTY },
            required:   %w[domain]
          }
        },
        {
          name:        "describe",
          description: "Zoom level two: one aggregate's full contract — every command's arguments, the states it " \
                       "may be issued from, and every way it can refuse. Omit `aggregate` for the whole domain.",
          inputSchema: {
            type:       "object",
            properties: {
              domain:    DOMAIN_PROPERTY,
              aggregate: { type: "string", description: "Narrow to one aggregate. Omit for the whole domain." }
            },
            required:   %w[domain]
          }
        },
        {
          name:        "validate",
          description: "Zoom level three: is this domain's wiring sound — every bind names a declared aggregate, " \
                       "every adapter satisfies its port, the default adapter is usable. {valid:false, error:…} " \
                       "on a real wiring defect, never a bare crash. Set `deep: true` to also model-check the IR " \
                       "for dead lifecycle transitions, unreachable saga states, and dispatches to nowhere.",
          inputSchema: {
            type:       "object",
            properties: {
              domain: DOMAIN_PROPERTY,
              deep:   { type: "boolean", description: "Also run the static model checker (lifecycle/saga/policy IR)." }
            },
            required:   %w[domain]
          }
        },
        {
          name:        "domains",
          description: "Zoom level zero: every domain directory found under a root (default \"examples\"), so a " \
                       "caller who doesn't already know a path can find one.",
          inputSchema: {
            type:       "object",
            properties: { under: { type: "string", description: "Root directory to scan. Defaults to \"examples\"." } }
          }
        },
        {
          name:        "history",
          description: "The full write history for every aggregate in a domain — every operation an append-only " \
                       "adapter ever recorded, not just current state. An aggregate on a non-append-only adapter " \
                       "answers an empty history honestly.",
          inputSchema: {
            type:       "object",
            properties: { domain: DOMAIN_PROPERTY },
            required:   %w[domain]
          }
        },
        {
          name:        "behaviors",
          description: "Run a domain's hand-curated `.behaviors` example tests and report pass/fail/error per test. " \
                       "`target` is a single `.behaviors` file or a directory to sweep.",
          inputSchema: {
            type:       "object",
            properties: { target: { type: "string", description: "A .behaviors file, or a directory to sweep." } },
            required:   %w[target]
          }
        },
        {
          name:        "follow",
          description: "Tail this door's own audit log for a domain — the last `limit` dispatch/query/state/dry-run " \
                       "calls made through it, each carrying its summary, source, and outcome.",
          inputSchema: {
            type:       "object",
            properties: {
              domain: DOMAIN_PROPERTY,
              limit:  { type: "integer", description: "How many recent entries to return. Defaults to 20." }
            },
            required:   %w[domain]
          }
        }
      ].freeze

      NOTES = [
        "Identity is self-asserted: role:/actor_id: are claims made by the caller and are not verified.",
        "state, events, history, follow, describe, catalog and query run with no role check at all.",
        "domain: boots real Ruby under #{Storehouse::BOOT_ROOT}; anyone who can write to stdin can run it."
      ].freeze

      module_function

      # Read once, so a bad setting refuses to start the door before anything is
      # written to stdout.
      def scope
        @scope ||= McpDoorScope.start!(server: CLI::Mcp::SERVER)
      end

      # The standing notes, then what this door's scope says about `domain:`.
      def warning_notes
        NOTES[0, 2] + (scope.restricted? ? scope.notes : [NOTES[2]])
      end

      def serve
        McpStdioGuard.warn!(server: CLI::Mcp::SERVER, notes: warning_notes)
        $stdout.sync = true

        $stdin.each_line do |line|
          line = line.strip
          next if line.empty?

          begin
            request = JSON.parse(line)
          rescue JSON::ParserError => e
            send_error(nil, -32_700, "Parse error: #{e.message}")
            next
          end

          begin
            handle(request)
          rescue StandardError => e
            send_error(request["id"], -32_603, "Internal error: #{e.class}: #{e.message}")
          end
        end
      end

      # `domain:` is confined to `Storehouse::BOOT_ROOT`, and further to a restricted
      # door's `HECKS_DOOR_DOMAINS`, before anything boots. An unrestricted door boots the
      # domain afresh on every call; a restricted door lives for one spawner's session and
      # keeps each named domain booted until the files of its directory change.
      def boot(domain)
        path = Storehouse.confine!(scope.admit_domain!(domain), "domain")
        return Hecks.boot(path, install_doors: false) unless scope.restricted?

        resident = (@resident ||= {})
        fingerprint = Storehouse.fingerprint(path)
        return resident[path][:runtime] if resident[path] && resident[path][:fingerprint] == fingerprint

        resident[path] = { fingerprint: fingerprint, runtime: Hecks.boot(path, install_doors: false) }
        resident[path][:runtime]
      end

      # One `when` per tool, so the shared `rescue` catches every branch's escape
      # once; a domain refusal is already `{ok: false, ...}` from `Storehouse`.
      def call_tool(name, args) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity
        case name
        when "dispatch" then dispatch_tool(args)
        when "query" then query_tool(args)
        when "events"
          Storehouse.events(runtime: boot(args["domain"]), aggregate: args["aggregate"], id: args["id"],
                            limit: args["limit"])
        when "state"
          Storehouse.state(runtime: boot(args["domain"]), aggregate: args["aggregate"],
                           summary: args["summary"], id: args["id"])
        when "catalog"
          Storehouse.catalog(runtime: boot(args["domain"]))
        when "describe"
          Storehouse.describe(runtime: boot(args["domain"]), aggregate: args["aggregate"])
        when "validate"
          Storehouse.validate(domain: scope.admit_domain!(args["domain"]), deep: args["deep"] == true)
        when "domains"
          Storehouse.domains(under: args["under"] || "examples")
        when "history"
          Storehouse.history(runtime: boot(args["domain"]))
        when "behaviors"
          Storehouse.behaviors(target: args["target"])
        when "follow"
          Storehouse.follow(runtime: boot(args["domain"]), limit: args["limit"] || 20)
        else
          { ok: false, error: "no such tool: #{name.inspect} — known: #{TOOLS.map { |t| t[:name] }.join(', ')}" }
        end
      rescue StandardError => e
        # A defect, not a refusal: reaching here means a bad domain path or an
        # argument shape `Doors::JsonDoor` could not symbolize.
        { ok: false, error: "#{e.class}: #{e.message}" }
      end

      # A question, once the scope has admitted its arguments.
      def query_tool(args)
        scope.admit_arguments!(args["args"])
        Storehouse.query(runtime: boot(args["domain"]), question: args["question"],
                         summary: args["summary"], args: args["args"] || {}, source: args["source"],
                         role: args["role"], actor_id: args["actor_id"])
      end

      # A single command or a batch, once the scope has admitted every command in it.
      def dispatch_tool(args)
        runtime = boot(args["domain"])
        if args["steps"]
          scope.admit_steps!(runtime, args["steps"])
          Storehouse.dispatch_batch(runtime: runtime, steps: args["steps"], summary: args["summary"],
                                    source: args["source"], role: args["role"], actor_id: args["actor_id"])
        else
          scope.admit_command!(runtime, args["command"], args["args"])
          Storehouse.dispatch(runtime: runtime, command: args["command"], summary: args["summary"],
                              args: args["args"] || {}, source: args["source"],
                              dry_run: args["dry_run"] == true, role: args["role"], actor_id: args["actor_id"])
        end
      end

      def answer_tool(name, args)
        return scope.refusal(name) unless scope.permits_tool?(name)

        call_tool(name, scope.with_default_domain(args))
      end

      # One line per allowed command: what it takes and the role it declares, read from the booted
      # domain the door serves. Nil when the door serves no single domain or it will not boot, so
      # `tools/list` still answers, with the commands as a bare list.
      def command_guide
        return unless scope.commands_mode? && scope.default_domain

        McpGuideCache.remember(scope.default_domain, scope.allowed_commands) do
          Storehouse.command_guide(boot(scope.default_domain), scope.allowed_commands)
        end
      rescue StandardError
        nil
      end

      def tool_result(payload)
        { content: [{ type: "text", text: JSON.pretty_generate(payload) }], isError: payload[:ok] == false }
      end

      def send_response(id, result)
        puts JSON.generate({ jsonrpc: "2.0", id: id, result: result })
      end

      def send_error(id, code, message)
        puts JSON.generate({ jsonrpc: "2.0", id: id, error: { code: code, message: message } })
      end

      def handle(request)
        id     = request["id"]
        method = request["method"]
        params = request["params"] || {}

        case method
        when "initialize"
          send_response(id, {
                          protocolVersion: PROTOCOL_VERSION,
                          capabilities:    { tools: {} },
                          serverInfo:      { name: CLI::Mcp::SERVER, version: "1.1.0" }
                        })
        when "notifications/initialized"
          nil # a notification — no id, no response
        when "tools/list"
          served = TOOLS.select { |tool| scope.permits_tool?(tool[:name]) }
          guide = command_guide
          send_response(id, { tools: served.map { |tool| scope.present(tool, guide) } })
        when "tools/call"
          send_response(id, tool_result(answer_tool(params["name"], params["arguments"] || {})))
        when "ping"
          send_response(id, {})
        else
          send_error(id, -32_601, "Method not found: #{method}") unless id.nil?
        end
      end
    end
  end
end
