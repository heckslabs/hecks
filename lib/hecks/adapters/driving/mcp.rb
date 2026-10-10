require "json"
require_relative "../.."
require_relative "../../cli/mcp"
require_relative "mcp/tool_definitions"
require_relative "mcp/tool_calls"

module Hecks
  module Adapters
    module Driving
      # The MCP server onto the storehouse bus: hand-rolled JSON-RPC over stdio, one
      # server per booted domain. All logic and the JSON shape answered with live in
      # `Storehouse`; this is plumbing only. A `role:`/`actor_id:` a caller sends is
      # asserted, not verified, unless Governance is attached.
      #
      # There is no authentication: `domain:` boots real Ruby confined to
      # `Storehouse::BOOT_ROOT`, so this is a code execution surface for anyone who
      # can write to stdin (ADR 0062). Spawning with `HECKS_SERVER_TOOLS=readers` and
      # `HECKS_SERVER_DOMAINS=<dir>[:<dir>...]` narrows a server to read-only tools and
      # named domains (`McpScope`); this limits what one agent can reach and is
      # not itself authentication.
      module Mcp
        PROTOCOL_VERSION = "2024-11-05".freeze

        TOOLS = ToolDefinitions::TOOLS

        NOTES = [
          "Identity is self-asserted: role:/actor_id: are claims made by the caller and are not verified.",
          "state, events, history, follow, describe, catalog and query run with no role check at all.",
          "domain: boots real Ruby under #{Storehouse::BOOT_ROOT}; anyone who can write to stdin can run it."
        ].freeze

        # The method that answers each JSON-RPC method that has a response.
        REPLIES = {
          "initialize" => :initialize_result,
          "tools/list" => :tools_list,
          "tools/call" => :tools_call,
          "ping"       => :ping_result
        }.freeze

        module_function

        # Read once, so a bad setting refuses to start the server before anything is
        # written to stdout.
        def scope
          @scope ||= McpScope.start!(server: CLI::Mcp::SERVER)
        end

        # The standing notes, then what this server's scope says about `domain:`.
        def warning_notes
          NOTES[0, 2] + (scope.restricted? ? scope.notes : [NOTES[2]])
        end

        def serve
          McpStdioGuard.warn!(server: CLI::Mcp::SERVER, notes: warning_notes)
          $stdout.sync = true

          $stdin.each_line { |line| answer_line(line.strip) }
        end

        # Answers one request line; a line that is not JSON is a parse error, not a crash.
        def answer_line(line)
          return if line.empty?

          handle_safely(JSON.parse(line))
        rescue JSON::ParserError => e
          send_error(nil, -32_700, "Parse error: #{e.message}")
        end

        # Handles a request, answering an internal error rather than ending the server.
        def handle_safely(request)
          handle(request)
        rescue StandardError => e
          send_error(request["id"], -32_603, "Internal error: #{e.class}: #{e.message}")
        end

        # `domain:` is confined to `Storehouse::BOOT_ROOT`, and further to a restricted
        # server's `HECKS_SERVER_DOMAINS`, before anything boots. An unrestricted server boots the
        # domain afresh on every call; a restricted server lives for one spawner's session and
        # keeps each named domain booted until the files of its directory change.
        def boot(domain)
          path = Storehouse.confine!(scope.admit_domain!(domain), "domain")
          return Hecks.boot(path, install_driving: false) unless scope.restricted?

          resident_boot(path)
        end

        # The runtime a restricted server keeps for `path`, booted again once its files change.
        def resident_boot(path)
          resident    = (@resident ||= {})
          fingerprint = Storehouse.fingerprint(path)
          return resident[path][:runtime] if resident[path] && resident[path][:fingerprint] == fingerprint

          resident[path] = { fingerprint: fingerprint, runtime: Hecks.boot(path, install_driving: false) }
          resident[path][:runtime]
        end

        def answer_tool(name, args)
          return scope.refusal(name) unless scope.permits_tool?(name)

          ToolCalls.call(name, scope.with_default_domain(args))
        end

        # One line per allowed command: what it takes and the role it declares, read from the booted
        # domain the server serves. Nil when the server serves no single domain or it will not boot,
        # so
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

        # Answers one JSON-RPC request. A notification has no id and gets no response.
        def handle(request)
          id     = request["id"]
          method = request["method"]
          reply  = REPLIES[method]
          return send_response(id, public_send(reply, request["params"] || {})) if reply

          send_error(id, -32_601, "Method not found: #{method}") unless id.nil? || method == "notifications/initialized"
        end

        def initialize_result(_params)
          { protocolVersion: PROTOCOL_VERSION, capabilities: { tools: {} },
            serverInfo: { name: CLI::Mcp::SERVER, version: "1.1.0" } }
        end

        # The tools this server's scope permits, each presented with the command guide.
        def tools_list(_params)
          served = TOOLS.select { |tool| scope.permits_tool?(tool[:name]) }
          guide  = command_guide
          { tools: served.map { |tool| scope.present(tool, guide) } }
        end

        def tools_call(params)
          tool_result(answer_tool(params["name"], params["arguments"] || {}))
        end

        def ping_result(_params) = {}
      end
    end
  end
end
