# frozen_string_literal: true

require "json"
require_relative "mcp_stdio_guard"
require_relative "query_ir"

module Hecks
  # The MCP server that exposes `Hecks::QueryIR`'s queries as tools, over newline-delimited
  # JSON-RPC.
  #
  # It is stdio only and unauthenticated (ADR 0062): {.start} refuses any other setup before it
  # reads a request. The query logic lives in `Hecks::QueryIR`; this is only the protocol.
  module QueryIrMcp
    # The MCP protocol revision the server speaks.
    PROTOCOL_VERSION = "2024-11-05"

    # The three tools, as an MCP client lists them.
    TOOLS = [
      {
        name:        "query_ir_constructs",
        description: "For a bluebook IR construct (Aggregate, Entity, Command, Query, ValueObject, Policy, " \
                     "ReadModel, ProcessManager, Bluebook) or all of them, the real structural diff between " \
                     "what the Ruby class emits and what the self-hosted meta-domain declares for it. Use " \
                     "this instead of reading entity.rb/entity.bluebook (or the equivalent pair for another " \
                     "construct) by hand to check whether a new IR field has been fully propagated.",
        inputSchema: {
          type:       "object",
          properties: {
            names: {
              type:        "array",
              items:       { type: "string" },
              description: "Construct names to check (e.g. [\"Entity\"]). Omit or leave empty for all constructs."
            }
          }
        }
      },
      {
        name:        "query_ir_duplicates",
        description: "Every given/ensures/invariant DECLARATION across the real corpus " \
                     "(banking/pizzas/compliance) and the self-hosted meta-domain, grouped by (kind, " \
                     "description, canonical predicate), reporting every group with more than one " \
                     "independently-declared rule (already-deduped references, which share the same " \
                     "underlying rule object, are excluded). Use this to find real corpus duplication " \
                     "before proposing a new 'declared once, referenced by name' resolution rule.",
        inputSchema: {
          type:       "object",
          properties: {
            domains:      {
              type:        "array",
              items:       { type: "string" },
              description: "Real example domain directories to scan (e.g. [\"examples/banking\"]). Omit for " \
                           "every real example domain."
            },
            include_meta: {
              type:        "boolean",
              description: "Include the self-hosted meta-domain (lib/hecks/language/bluebook). Defaults to true."
            }
          }
        }
      },
      {
        name:        "query_ir_impact",
        description: "For one construct/field pair, which of the six propagation touchpoints " \
                     ".claude/skills/bluebook-construct-creator/SKILL.md walks in prose already show signs " \
                     "of it, and which don't: the meta-domain grammar, docs/resolution-rules/, " \
                     "Assembly::Contracts, Reconstruction's hand-typed aggregate(row)/entity(row) (only " \
                     "applicable to Aggregate/Entity), the fuzzer's FEATURE_COVERAGE/" \
                     "GUARANTEED_BY_CONSTRUCTION, and the Rust mirror. Advisory, not a gate.",
        inputSchema: {
          type:       "object",
          properties: {
            name:  { type: "string", description: "Construct name (e.g. \"Aggregate\")." },
            field: { type: "string", description: "The field name to check (e.g. \"preconditions\")." }
          },
          required:   %w[name field]
        }
      }
    ].freeze

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
      when "query_ir_constructs"
        tool_result(QueryIR.format_constructs(QueryIR.constructs(Array(arguments["names"]))))
      when "query_ir_duplicates" then tool_result(duplicates(arguments))
      when "query_ir_impact"
        tool_result(QueryIR.format_impact_preview(QueryIR.impact_preview(arguments["name"], arguments["field"])))
      else
        tool_result("no such tool: #{name.inspect} - known: #{TOOLS.map { |t| t[:name] }.join(', ')}", error: true)
      end
    rescue ArgumentError, Runtime::TypeMismatch => e
      tool_result(e.message, error: true)
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
      params = request["params"] || {}
      case request["method"]
      when "initialize" then result(output, id, initialized)
      when "notifications/initialized" then nil
      when "tools/list" then result(output, id, { tools: TOOLS })
      when "tools/call" then result(output, id, call_tool(params["name"], params["arguments"] || {}))
      when "ping" then result(output, id, {})
      else error(output, id, -32_601, "Method not found: #{request['method']}") unless id.nil?
      end
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
