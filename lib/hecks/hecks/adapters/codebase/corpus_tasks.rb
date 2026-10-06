# frozen_string_literal: true

require "hecks/corpus"
require "hecks/query_ir"
require "hecks/query_ir_mcp"
require_relative "tree"
require "hecks/rust_build"
require_relative "../console_capture"

module Hecks
  module Adapters
    module Codebase
      # What Codebase's `CorpusRun` asks of the working tree: which committed domains have a Rust
      # feature, what the language's IR holds, and the two doors that serve it.
      #
      # The questions are pure reads and run in this process, with the code `hecks rust_domains` and
      # `hecks ir_constructs` run (`Hecks::Corpus`, `Hecks::QueryIR`); the coverage question runs
      # `Hecks::RustBuild`'s coverage tool over each generated module, also in this process. The
      # two doors run until they are closed: the query MCP server on stdio, and the forms app on a
      # local port.
      module CorpusTasks
        # Every operation this family carries out.
        OPERATIONS = %w[serve_query_ir_mcp present].freeze

        # The port `present` listens on when none is named.
        DEFAULT_PORT = 4567

        class << self
          # @return [#call, nil] serves the MCP door; `Hecks::QueryIrMcp.start` when nil. A spec
          #   replaces it so no stdio has to be held.
          attr_accessor :mcp_server

          # @return [#call, nil] takes `app:` and `port:` and serves until stopped; a WEBrick
          #   server through Rack when nil.
          attr_accessor :web_server

          # @return [#capture, nil] runs each coverage check, as `capture(tool, argv, env:)`
          #   answering an object with `out`, `err` and `ok?`; `Hecks::RustBuild` when nil.
          attr_accessor :coverage_runner
        end

        module_function

        # Opens one of the doors.
        #
        # @param operation [String] `serve_query_ir_mcp` or `present`
        # @param held [Hash] the `CorpusRun` record's fields: `port`
        # @param tree [Tree] the working tree, already known to be a hecks checkout
        # @param shell [#capture, nil] unused
        # @return [String] a note that the door closed
        # @raise [ConsoleCapture::Failure] when the MCP door refuses the process's setup
        def call(operation, held, tree, shell: nil)
          _ = shell
          return serve_mcp if operation == "serve_query_ir_mcp"

          present(plain(held)[:port] || DEFAULT_PORT, tree)
        end

        # A pure read.
        #
        # @param operation [String] a query's name in snake case
        # @param args [Hash] the query's plain arguments
        # @param tree [Tree] the checkout
        # @param shell [#capture, nil] unused; the coverage checks run in this process
        # @return [String] the answer, one line for each row
        # @raise [ConsoleCapture::Failure] when a coverage check fails, or a query is refused
        def report(operation, args, tree, shell: nil)
          _ = shell
          case operation
          when "rust_domains" then rust_domains(tree)
          when "regen_order" then regen_order(tree)
          when "corpus_rust_coverage" then coverage(tree)
          else ir_query(operation, args)
          end
        end

        # @param held [Hash] fields, each perhaps a value object's `{ value: x }`
        # @return [Hash] the same fields as plain values
        def plain(held) = held.transform_values { |value| value.is_a?(Hash) ? value[:value] : value }

        # @return [String] a note that the MCP door closed
        # @raise [ConsoleCapture::Failure] when the door refuses to start
        def serve_mcp
          server = CorpusTasks.mcp_server || ->(**options) { QueryIrMcp.start(**options) }
          server.call(argv: [])
          "query ir mcp door closed"
        rescue SystemExit => e
          raise ConsoleCapture::Failure, "the query ir mcp door refused to start (status #{e.status}); see stderr"
        end

        # @param port [Integer] the port to listen on
        # @param tree [Tree] the checkout
        # @return [String] a note that the server stopped
        def present(port, tree)
          require "hecks/forms/banking_presentation"
          app = Forms::BankingPresentation.app(root: tree.root)
          warn "banking forms, in memory, on http://localhost:#{port}/ - no authentication, no CSRF " \
               "protection, no caller identity; do not expose beyond localhost"
          (CorpusTasks.web_server || method(:rack_serve)).call(app: app, port: port)
          "presented on port #{port}, now stopped"
        end

        # @param app [#call] the Rack app
        # @param port [Integer] the port
        # @return [void]
        def rack_serve(app:, port:)
          require "rackup"
          Rackup::Server.start(app: app, Port: port, server: "webrick")
        end

        # @param tree [Tree] the checkout
        # @return [String] each domain with a Rust feature: its feature, a tab, and its directory
        def rust_domains(tree)
          Corpus.rust_domains(root: tree.root).map { |domain| "#{domain.feature}\t#{tree.relative(domain.dir)}" }
                .join("\n")
        end

        # @param tree [Tree] the checkout
        # @return [String] the directories regeneration walks, in order, one for each line
        def regen_order(tree)
          Corpus.rust_regen_order(root: tree.root).map { |domain| tree.relative(domain.dir) }.join("\n")
        end

        # Runs the coverage tool over every generated module. A module named in
        # `Corpus::RUST_COVERAGE_PENDING` must still fail; every other one must pass.
        #
        # @param tree [Tree] the checkout
        # @return [String] one line for each module, and how many were checked
        # @raise [ConsoleCapture::Failure] with every module that failed, or that passes now while
        #   still listed as pending
        def coverage(tree)
          modules = Corpus.generated_modules(root: tree.root)
          pending = Corpus::RUST_COVERAGE_PENDING
          unknown = pending.keys - modules
          raise ConsoleCapture::Failure, "pending names #{unknown.join(", ")}, with no generated module" if unknown.any?

          lines, problems = judge(modules, pending, coverage_results(modules, tree))
          raise ConsoleCapture::Failure, [*lines, "", *problems].join("\n") if problems.any?

          [*lines, "#{modules.size} generated modules checked"].join("\n")
        end

        # @param modules [Array<String>] the generated modules
        # @param pending [Hash{String => String}] the modules known to fail, and why
        # @param results [Hash{String => Array}] each module's `[passed, output]`
        # @return [Array(Array<String>, Array<String>)] the report lines and the problems
        def judge(modules, pending, results)
          problems = []
          lines = modules.map do |name|
            passed, output = results.fetch(name)
            if pending.key?(name)
              problems << "#{name} passes now - delete it from Hecks::Corpus::RUST_COVERAGE_PENDING" if passed
              "#{name}: pending (#{passed ? "NOW PASSES" : "still fails"}) - #{pending[name]}"
            else
              problems << "#{name} failed:\n#{output}" unless passed
              "#{name}: #{passed ? "ok" : "FAILED"}"
            end
          end
          [lines, problems]
        end

        # @param modules [Array<String>] the generated modules
        # @param tree [Tree] the checkout
        # @return [Hash{String => Array}] each module's `[passed, output]`
        def coverage_results(modules, tree)
          runner = CorpusTasks.coverage_runner || RustBuild
          env = { "HECKS_RUST_DIR" => tree.path("rust") }
          modules.to_h do |name|
            result = runner.capture("rust_coverage", [name], env: env)
            [name, [result.ok?, [result.out, result.err].join]]
          end
        end

        # @param operation [String] `ir_constructs`, `ir_duplicates` or `ir_impact`
        # @param args [Hash] the query's plain arguments
        # @return [String] the formatted answer
        # @raise [ConsoleCapture::Failure] when the query refuses its arguments
        def ir_query(operation, args)
          case operation
          when "ir_constructs" then QueryIR.format_constructs(QueryIR.constructs(words(args[:names])))
          when "ir_duplicates" then duplicates(args)
          else QueryIR.format_impact_preview(QueryIR.impact_preview(args[:name], args[:field]))
          end
        rescue ArgumentError => e
          raise ConsoleCapture::Failure, e.message
        end

        # @param args [Hash] `domains` and `meta`
        # @return [String] the duplicated rules; the meta-domain is included when asked for, or
        #   when no domain is named
        def duplicates(args)
          domains = args[:domains] ? words(args[:domains]) : nil
          QueryIR.format_duplicates(QueryIR.duplicates(domains: domains, include_meta: args[:meta] == true || domains.nil?))
        end

        # @param list [String, nil] a comma-separated list
        # @return [Array<String>] its items
        def words(list) = list.to_s.split(",").map(&:strip).reject(&:empty?)
      end
    end
  end
end
