require "json"
require_relative "../../hecks"
require_relative "mcp"

module Hecks
  module CLI
    # The MCP door onto the storehouse bus: one MCP server for every booted domain,
    # not one per command, hand-rolled JSON-RPC over stdio (newline-delimited JSON,
    # flushed after every write, no gem dependency).
    #
    # ## Plumbing only
    #
    # All the logic and the JSON shape it answers with live in `Storehouse`, the bus
    # itself, transport-blind. A door of another shape (a plain CLI, an HTTP door)
    # would sit beside this one, calling `Storehouse` the same way and sharing its
    # audit log and caller-identity handling.
    #
    # ## Identity is asserted, not verified
    #
    # `dispatch` and `query` take `role:` and `actor_id:`, bound for the call through
    # `Hecks.as_caller`, so a role-gated command is checked against them rather than
    # merely documented by `describe`; `dispatch` refuses a role-declaring command
    # called without one. Nothing here verifies the claim beyond the string (or, with
    # Governance attached, a `Governance::RoleAssignment` lookup). The readers take
    # no role, and `query` gates on none.
    #
    # ## Stdio only, enforced
    #
    # The door has no authentication. `Mcp.call` runs
    # `McpStdioGuard.enforce_stdio!` before this file loads, and `serve` prints the
    # warning to stderr, never stdout, which carries the protocol. `domain:` is
    # confined to `Storehouse::BOOT_ROOT` (`confine!`), but a domain within that
    # root still boots real Ruby, so this is a code execution surface for anyone who
    # can write to stdin. A network transport needs authentication first; see
    # `docs/decisions/0062-mcp-servers-need-real-authentication-before-any-network-transport.md`.
    #
    # ## One boot per call
    #
    # `Hecks.boot(domain, install_facade: false)` is cheap, and it lets one server
    # answer calls against two domains back to back with no shared, staling state.
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

      # Prints the stdio warning to stderr, then answers one JSON-RPC request per
      # line of `$stdin` until it closes.
      #
      # @return [void]
      def serve
        McpStdioGuard.warn!(server: Mcp::SERVER, notes: NOTES)
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

      # Boots one domain for a single call, confined to `Storehouse::BOOT_ROOT`.
      #
      # @param domain [String] the domain directory, e.g. `"examples/banking"`
      # @return [Runtime::Dispatcher, Runtime::RemoteDispatcher] the booted domain
      # @raise [Runtime::TypeMismatch] if `domain` resolves outside `Storehouse::BOOT_ROOT`
      # @raise [Runtime::WiringError] if the domain fails to boot
      def boot(domain) = Hecks.boot(Storehouse.confine!(domain, "domain"), install_facade: false)

      # Runs one registered MCP tool by delegating to the matching `Storehouse` call.
      #
      # A closed-set dispatch table, one `when` per tool, so the size is the tool
      # count and the shared `rescue` catches every branch's escape once.
      #
      # @param name [String] the tool name, one of `TOOLS`'s own `:name` values
      # @param args [Hash{String => Object}] the tool's JSON arguments, shaped per that
      #   tool's `inputSchema`
      # @return [Hash{Symbol => Object}] the delegated `Storehouse` result on a known
      #   tool name; `{ok: false, error: String}` for an unknown tool name or any
      #   `StandardError` this door did not anticipate (a domain refusal is already
      #   `{ok: false, ...}` from inside `Storehouse` itself)
      def call_tool(name, args) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity
        case name
        when "dispatch"
          runtime = boot(args["domain"])
          if args["steps"]
            Storehouse.dispatch_batch(runtime: runtime, steps: args["steps"], summary: args["summary"],
                                      source: args["source"], role: args["role"], actor_id: args["actor_id"])
          else
            Storehouse.dispatch(runtime: runtime, command: args["command"], summary: args["summary"],
                                args: args["args"] || {}, source: args["source"],
                                dry_run: args["dry_run"] == true, role: args["role"], actor_id: args["actor_id"])
          end
        when "query"
          Storehouse.query(runtime: boot(args["domain"]), question: args["question"],
                           summary: args["summary"], args: args["args"] || {}, source: args["source"],
                           role: args["role"], actor_id: args["actor_id"])
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
          Storehouse.validate(domain: args["domain"], deep: args["deep"] == true)
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
        # **A defect, not a refusal** — every domain refusal is already answered as
        # `{ok: false, error: "..."}` inside `Storehouse`. Reaching here means a bad
        # domain path or an argument shape `Facade::JsonDoor` could not symbolize,
        # still answered as structured content rather than an MCP-level `isError`,
        # so a calling agent reads one shape for every outcome.
        { ok: false, error: "#{e.class}: #{e.message}" }
      end

      # Wraps a `call_tool` payload in the MCP `tools/call` result shape.
      #
      # @param payload [Hash{Symbol => Object}] a `call_tool` result
      # @return [Hash{Symbol => Object}] `{content: [{type: "text", text: ...}], isError: Boolean}`,
      #   pretty-printing `payload` as the text and setting `isError` from `payload[:ok]`
      def tool_result(payload)
        { content: [{ type: "text", text: JSON.pretty_generate(payload) }], isError: payload[:ok] == false }
      end

      # Writes one JSON-RPC success response line to stdout.
      #
      # @param id [String, Integer, nil] the request's own `id`, echoed back
      # @param result [Object] the JSON-serializable result payload
      # @return [void]
      def send_response(id, result)
        puts JSON.generate({ jsonrpc: "2.0", id: id, result: result })
      end

      # Writes one JSON-RPC error response line to stdout.
      #
      # @param id [String, Integer, nil] the request's own `id`, echoed back; nil when
      #   the request itself could not be parsed
      # @param code [Integer] the JSON-RPC error code
      # @param message [String] the error message
      # @return [void]
      def send_error(id, code, message)
        puts JSON.generate({ jsonrpc: "2.0", id: id, error: { code: code, message: message } })
      end

      # Dispatches one parsed JSON-RPC request to its method and writes the response.
      #
      # @param request [Hash{String => Object}] one parsed JSON-RPC request, with
      #   `"id"`, `"method"`, and optional `"params"`
      # @return [void]
      def handle(request)
        id     = request["id"]
        method = request["method"]
        params = request["params"] || {}

        case method
        when "initialize"
          send_response(id, {
                          protocolVersion: PROTOCOL_VERSION,
                          capabilities:    { tools: {} },
                          serverInfo:      { name: Mcp::SERVER, version: "1.1.0" }
                        })
        when "notifications/initialized"
          nil # a notification — no id, no response
        when "tools/list"
          send_response(id, { tools: TOOLS })
        when "tools/call"
          send_response(id, tool_result(call_tool(params["name"], params["arguments"] || {})))
        when "ping"
          send_response(id, {})
        else
          send_error(id, -32_601, "Method not found: #{method}") unless id.nil?
        end
      end
    end
  end
end
