require "webrick"
require "json"
require "tmpdir"

module Hecks
  module HTTP
    # Hecks::HTTP::RpcServer
    #
    # WEBrick-based JSON-RPC 2.0 server for a Hecks domain. Provides a single
    # POST endpoint that dispatches to commands, queries, and CRUD methods for
    # each aggregate. Boots the domain gem from a temporary directory (same
    # approach as {DomainServer}).
    #
    # RPC method naming conventions:
    # - Commands: use the command class name (e.g. "CreatePizza")
    # - Queries: use "AggregateName.query_name" (e.g. "Pizza.by_topping")
    # - CRUD: use "AggregateName.find", ".all", ".count", ".delete"
    #
    #   hecks serve pizzas_domain --rpc
    #
    #   # JSON-RPC request:
    #   # POST / {"jsonrpc":"2.0","method":"CreatePizza","params":{"name":"Margherita"},"id":1}
    #
    class RpcServer
      include HecksTemplating::NamingHelpers
      # Initialize the RPC server, boot the domain, and register all methods.
      #
      # Builds the domain gem into a temp directory, boots it, then
      # registers RPC methods for all commands, queries, and CRUD operations
      # across all aggregates.
      #
      # @param domain [Hecks::Domain] the domain definition to serve
      # @param port [Integer] the TCP port to listen on (default: 9292)
      # @return [RpcServer] a new server instance ready to run
      def initialize(domain, port: 9292)
        @domain = domain
        @port = port
        @methods = {}
        boot_domain
        @whitelist = Hecks::Conventions::DispatchContract.build_whitelist(domain)
        register_methods
      end

      # Start the WEBrick server and begin handling JSON-RPC requests.
      #
      # Prints available RPC methods to stdout, then enters the WEBrick
      # event loop. Blocks until the process receives an INT signal.
      #
      # @return [void]
      def run
        puts "Hecks RPC serving #{@domain.name} on http://localhost:#{@port}"
        puts ""
        puts "Methods:"
        @methods.each_key { |m| puts "  #{m}" }
        puts ""

        server = WEBrick::HTTPServer.new(Port: @port, Logger: WEBrick::Log.new("/dev/null"), AccessLog: [])
        server.mount_proc("/") { |req, res| handle(req, res) }
        trap("INT") { server.shutdown }
        server.start
      end

      private

      # Dispatch a JSON-RPC 2.0 request to the appropriate method handler.
      #
      # Parses the JSON body, looks up the method by name, calls it with
      # the provided params, and wraps the result in a JSON-RPC response.
      # Handles parse errors (-32700) and method-not-found errors (-32601).
      #
      # @param req [WEBrick::HTTPRequest] the incoming HTTP request
      # @param res [WEBrick::HTTPResponse] the outgoing HTTP response
      # @return [void]
      def handle(req, res)
        res["Access-Control-Allow-Origin"] = "*"
        res["Access-Control-Allow-Methods"] = "POST, OPTIONS"
        res["Access-Control-Allow-Headers"] = "Content-Type"
        res["Content-Type"] = "application/json"
        return if req.request_method == "OPTIONS"

        body = req.body || ""
        if body.empty?
          res.body = JSON.generate(jsonrpc: "2.0", error: { code: -32700, message: "Parse error" }, id: nil)
          return
        end

        request = JSON.parse(body)
        method_name = request["method"]
        params = request["params"] || {}
        id = request["id"]

        handler = @methods[method_name]
        unless handler
          res.body = JSON.generate(jsonrpc: "2.0", error: { code: -32601, message: "Method not found: #{method_name}" }, id: id)
          return
        end

        result = handler.call(params)
        res.body = JSON.generate(jsonrpc: "2.0", result: result, id: id)
      rescue JSON::ParserError
        res.body = JSON.generate(jsonrpc: "2.0", error: { code: -32700, message: "Parse error" }, id: nil)
      rescue => e
        res.body = JSON.generate(jsonrpc: "2.0", error: { code: -32000, message: e.message }, id: request&.dig("id"))
      end

      # Build the domain gem into a temp directory and boot it.
      #
      # Same approach as {DomainServer#boot_domain}: creates a temporary
      # directory, builds the gem, adds lib to $LOAD_PATH, and creates
      # a Runtime instance.
      #
      # @return [void]
      def boot_domain
        mod_name = domain_module_name(@domain.name)
        unless Object.const_defined?(mod_name)
          tmpdir = Dir.mktmpdir("hecks_rpc")
          gem_path = Hecks.build(@domain, output_dir: tmpdir)
          lib_path = File.join(gem_path, "lib")
          $LOAD_PATH.unshift(lib_path) unless $LOAD_PATH.include?(lib_path)
          require @domain.gem_name
          Dir[File.join(lib_path, "**/*.rb")].sort.each { |f| require f }
        end
        @mod = Object.const_get(mod_name)
        @app = Runtime.new(@domain)
      end

      # Register all RPC methods for all aggregates.
      #
      # Iterates each aggregate and registers command methods, query methods,
      # and CRUD methods into the @methods hash.
      #
      # @return [void]
      def register_methods
        @domain.aggregates.each do |agg|
          klass = @mod.const_get(domain_constant_name(agg.name))
          register_commands(agg, klass)
          register_queries(agg, klass)
          register_crud(agg, klass)
        end
      end

      # Register RPC methods for an aggregate's commands.
      #
      # Each command is registered by its class name (e.g. "CreatePizza").
      # The handler converts string-keyed params to symbol-keyed and calls
      # the derived method on the aggregate class.
      #
      # @param agg [Hecks::DomainModel::Structure::Aggregate] the aggregate definition
      # @param klass [Class] the aggregate's Ruby class
      # @return [void]
      def register_commands(agg, klass)
        agg.commands.each do |cmd|
          method_name = domain_command_method(cmd.name, agg.name)
          Hecks::Conventions::DispatchContract.validate!(@whitelist, agg.name, method_name)
          @methods[cmd.name] = ->(params) {
            serialize(klass.send(method_name, **params.transform_keys(&:to_sym)))
          }
        end
      end

      # Register RPC methods for an aggregate's custom queries.
      #
      # Each query is registered as "AggregateName.query_name" (e.g.
      # "Pizza.by_topping"). The handler maps parameter names from the
      # query block's parameter list to values in the params hash.
      #
      # @param agg [Hecks::DomainModel::Structure::Aggregate] the aggregate definition
      # @param klass [Class] the aggregate's Ruby class
      # @return [void]
      def register_queries(agg, klass)
        agg.queries.each do |query|
          qn = domain_snake_name(query.name)
          Hecks::Conventions::DispatchContract.validate!(@whitelist, agg.name, qn.to_sym)
          params = query.block.parameters
          @methods["#{agg.name}.#{qn}"] = ->(p) {
            args = params.map { |_, name| p[name.to_s] }
            results = params.empty? ? klass.send(qn.to_sym) : klass.send(qn.to_sym, *args)
            results.respond_to?(:map) ? results.map { |r| serialize(r) } : results
          }
        end
      end

      # Register standard CRUD RPC methods for an aggregate.
      #
      # Registers four methods:
      # - "AggregateName.find" -- find by ID, raises if not found
      # - "AggregateName.all" -- return all entities
      # - "AggregateName.count" -- return entity count
      # - "AggregateName.delete" -- delete by ID, returns confirmation
      #
      # @param agg [Hecks::DomainModel::Structure::Aggregate] the aggregate definition
      # @param klass [Class] the aggregate's Ruby class
      # @return [void]
      def register_crud(agg, klass)
        name = agg.name
        @methods["#{name}.find"] = ->(p) {
          result = klass.find(p["id"])
          result ? serialize(result) : (raise "Not found")
        }
        @methods["#{name}.all"] = ->(_) { klass.all.map { |r| serialize(r) } }
        @methods["#{name}.count"] = ->(_) { klass.count }
        @methods["#{name}.delete"] = ->(p) { klass.delete(p["id"]); { deleted: p["id"] } }
      end

      # Serialize a domain object into a plain Hash using Hecks::Utils.
      #
      # @param obj [Object] the domain object to serialize
      # @return [Hash{String => Object}] serialized attribute hash
      def serialize(obj)
        Hecks::Utils.serialize_object(obj)
      end
    end
  end
end
