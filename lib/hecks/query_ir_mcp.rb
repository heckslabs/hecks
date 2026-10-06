# frozen_string_literal: true

require "json"
require_relative "mcp_stdio_guard"
require_relative "query_ir"
require_relative "query_ir_mcp/tools"

module Hecks
  # The MCP server that exposes `Hecks::QueryIR`'s queries as tools, over newline-delimited
  # JSON-RPC.
  #
  # It is stdio only and unauthenticated (ADR 0062): {.start} refuses any other setup before it
  # reads a request. The query logic lives in `Hecks::QueryIR`; this is only the protocol.
  module QueryIrMcp
    # The MCP protocol revision the server speaks.
    PROTOCOL_VERSION = "2024-11-05"

    module_function

    # Checks the process is set up for stdio, prints the startup warning to stderr, and serves
    # requests until stdin closes.
    #
    # @param argv [Array<String>] the arguments the guard checks (only `--stdio` is accepted)
    # @param input [IO] where requests arrive
    # @param output [IO] where responses leave
    # @return [void]
    # @raise [SystemExit] when the setup is not stdio, with the guard's status
    def start(argv: [], input: $stdin, output: $stdout)
      McpStdioGuard.start!(server: "hecks-query-ir", notes: notes, argv: argv, stdin: input, stdout: output)
      serve(input: input, output: output)
    end

    # @return [Array<String>] what the startup warning says beyond the guard's common lines
    def notes
      ["No identity is asked for or checked; every tool answers every caller.",
       "query_ir_duplicates loads .bluebook files under #{Storehouse::BOOT_ROOT} as Ruby."]
    end

    # Answers each request line until the input ends.
    #
    # @param input [#each_line] newline-delimited JSON-RPC requests
    # @param output [#puts] where each response is written, one JSON object a line
    # @return [void]
    def serve(input:, output:)
      output.sync = true if output.respond_to?(:sync=)
      input.each_line do |line|
        line = line.strip
        next if line.empty?

        request = parse(line, output)
        respond(request, output) if request
      end
    end

    # @param name [String] the tool
    # @param arguments [Hash] its arguments as the client sent them
    # @return [Hash] the MCP tool result
    def call_tool(name, arguments)
      case name
      when "query_ir_constructs" then tool_result(constructs(arguments))
      when "query_ir_duplicates" then tool_result(duplicates(arguments))
      when "query_ir_impact" then tool_result(impact(arguments))
      else
        tool_result("no such tool: #{name.inspect} - known: #{TOOLS.map { |t| t[:name] }.join(", ")}", error: true)
      end
    rescue ArgumentError, Runtime::TypeMismatch => e
      tool_result(e.message, error: true)
    end

    # @api private
    def constructs(arguments)
      QueryIR.format_constructs(QueryIR.constructs(Array(arguments["names"])))
    end

    # @api private
    def impact(arguments)
      QueryIR.format_impact_preview(QueryIR.impact_preview(arguments["name"], arguments["field"]))
    end

    # @api private
    def duplicates(arguments)
      domains = confined_domains(arguments["domains"])
      QueryIR.format_duplicates(QueryIR.duplicates(domains: domains, include_meta: arguments.fetch("include_meta", true)))
    end

    # `duplicates` loads every .bluebook under each directory as Ruby, so paths must stay in the
    # storehouse boot root.
    #
    # @api private
    def confined_domains(requested)
      return nil if requested.nil? || requested.empty?

      Array(requested).map { |dir| Storehouse.confine!(dir, "domains") }
    end

    # @api private
    def tool_result(text, error: false)
      { content: [{ type: "text", text: text }], isError: error }
    end

    # @api private
    def parse(line, output)
      JSON.parse(line)
    rescue JSON::ParserError => e
      error(output, nil, -32_700, "Parse error: #{e.message}")
      nil
    end

    # @api private
    def respond(request, output)
      handle(request, output)
    rescue StandardError => e
      error(output, request["id"], -32_603, "Internal error: #{e.class}: #{e.message}")
    end

    # @api private
    def handle(request, output)
      id = request["id"]
      case request["method"]
      when "initialize" then result(output, id, initialized)
      when "notifications/initialized" then nil
      when "tools/list" then result(output, id, { tools: TOOLS })
      when "tools/call" then result(output, id, tools_call(request["params"]))
      when "ping" then result(output, id, {})
      else method_not_found(output, id, request["method"])
      end
    end

    # @api private
    def tools_call(params)
      params ||= {}
      call_tool(params["name"], params["arguments"] || {})
    end

    # @api private
    def method_not_found(output, id, method)
      error(output, id, -32_601, "Method not found: #{method}") unless id.nil?
    end

    # @api private
    def initialized
      { protocolVersion: PROTOCOL_VERSION, capabilities: { tools: {} },
        serverInfo: { name: "hecks-query-ir", version: "1.0.0" } }
    end

    # @api private
    def result(output, id, body) = output.puts(JSON.generate({ jsonrpc: "2.0", id: id, result: body }))

    # @api private
    def error(output, id, code, message)
      output.puts(JSON.generate({ jsonrpc: "2.0", id: id, error: { code: code, message: message } }))
    end
  end
end
