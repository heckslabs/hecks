require "webrick"
require "json"
require "stringio"
require "tmpdir"
require_relative "route_builder"
require_relative "command_bus_port"
require_relative "csrf_helpers"

module Hecks
  module HTTP
    # Hecks::HTTP::DomainServer
    #
    # WEBrick-based REST server that serves a Hecks domain over HTTP with CORS
    # support. On initialization, builds the domain gem into a temp directory,
    # boots it, and delegates route generation to {RouteBuilder}. Exposes CRUD
    # endpoints for each aggregate, query endpoints, and a +/events+ endpoint
    # that returns the domain's event history as JSON.
    #
    # Optionally supports WebSocket live events via the +hecks_sockets+ gem.
    # When +--live+ is enabled, a WebSocket server runs alongside HTTP on a
    # separate port.
    #
    #   hecks serve pizzas_domain
    #   hecks serve pizzas_domain --live
    #
    class DomainServer
      include HecksTemplating::NamingHelpers
      include CsrfHelpers
      # Initialize the server, boot the domain gem, and build routes.
      #
      # Builds the domain gem into a temporary directory, requires it,
      # creates a Runtime, and generates REST routes via RouteBuilder.
      #
      # @param domain [Hecks::Domain] the domain definition to serve
      # @param port [Integer] the TCP port for the HTTP server (default: 9292)
      # @param live [Boolean] whether to start a WebSocket server alongside
      #   HTTP for real-time event streaming (default: false)
      # @param live_port [Integer] the TCP port for the WebSocket server
      #   (default: 9293, only used when +live+ is true)
      # @return [DomainServer] a new server instance ready to run
      def initialize(domain, port: 9292, live: false, live_port: 9293)
        @domain = domain
        @port = port
        @live = live
        @live_port = live_port
        @sse_clients = []
        boot_domain
      end

      # Start the WEBrick HTTP server and begin handling requests.
      #
      # Prints the route table to stdout, optionally starts the WebSocket
      # server, then enters the WEBrick event loop. Blocks until the process
      # receives an INT signal (Ctrl-C).
      #
      # @return [void]
      def run
        puts "Hecks serving #{@domain.name} on http://localhost:#{@port}"
        puts ""
        @routes.each { |r| puts "  #{r[:method].ljust(6)} #{r[:path]}" }
        puts "  GET    /events (SSE)"
        puts "  GET    /_openapi"
        puts "  GET    /_schema"
        start_websocket_server if @live
        puts ""

        server = WEBrick::HTTPServer.new(Port: @port, Logger: WEBrick::Log.new("/dev/null"), AccessLog: [])
        server.mount_proc("/") { |req, res| handle(req, res) }
        trap("INT") { server.shutdown }
        server.start
      end

      private

      # Dispatch an incoming HTTP request to the appropriate route handler.
      #
      # Sets CORS headers on every response. Handles OPTIONS preflight
      # requests by returning immediately. Routes +/events+ to the event
      # history endpoint. For all other paths, finds a matching route and
      # delegates to its handler lambda.
      #
      # @param req [WEBrick::HTTPRequest] the incoming HTTP request
      # @param res [WEBrick::HTTPResponse] the outgoing HTTP response
      # @return [void]
      def handle(req, res)
        set_cors(res)
        return if req.request_method == "OPTIONS"

        if csrf_required?(req) && !valid_csrf_json?(req)
          res.status = 403
          res["Content-Type"] = "application/json"
          res.body = JSON.generate(error: "CSRF token mismatch")
          return
        end

        if req.path == "/events"
          # SSE not supported in basic WEBrick — return event list instead
          res["Content-Type"] = "application/json"
          res.body = JSON.generate(@app.events.map { |e| { type: Hecks::Utils.const_short_name(e), occurred_at: e.occurred_at.iso8601 } })
          return
        end

        if req.path == "/_openapi"
          res["Content-Type"] = "application/json"
          res.body = JSON.generate(Hecks::HTTP::OpenapiGenerator.new(@domain).generate)
          return
        end

        if req.path == "/_schema"
          res["Content-Type"] = "application/json"
          res.body = JSON.generate(Hecks::HTTP::JsonSchemaGenerator.new(@domain).generate)
          return
        end

        route = @routes.find { |r| r[:method] == req.request_method && match?(r[:path], req.path) }
        unless route
          res.status = 404
          res["Content-Type"] = "application/json"
          res.body = JSON.generate(error: "Not found")
          return
        end

        wrapper = RequestWrapper.new(req)
        result = route[:handler].call(wrapper)
        res["Content-Type"] = "application/json"
        res.body = JSON.generate(result)
      rescue => e
        res.status = 422
        res["Content-Type"] = "application/json"
        res.body = JSON.generate(error: e.message)
      end

      # Start a WebSocket server for real-time event streaming.
      #
      # Requires the +hecks_sockets+ gem and starts an async WebSocket
      # server on the configured live_port. If the gem is not available,
      # prints a warning and continues without WebSocket support.
      #
      # @return [void]
      def start_websocket_server
        require "hecks_sockets"
        handler = HecksSockets::WebsocketHandler.new(@domain, @app)
        bus = @app.event_bus
        ws = HecksSockets::WebsocketServer.new(handler, bus, gate: @live_port)
        ws.start_async
      rescue LoadError
        warn "[hecks] hecks_sockets gem not found — skipping WebSocket server"
      end

      # Build the domain gem into a temp directory and boot it.
      #
      # Creates a temporary directory, builds the domain gem there,
      # adds its lib path to $LOAD_PATH, requires all generated files,
      # then creates a Runtime and generates routes via RouteBuilder.
      #
      # @return [void]
      def boot_domain
        mod_name = domain_module_name(@domain.name)
        unless Object.const_defined?(mod_name)
          tmpdir = Dir.mktmpdir("hecks_serve")
          gem_path = Hecks.build(@domain, output_dir: tmpdir)
          lib_path = File.join(gem_path, "lib")
          $LOAD_PATH.unshift(lib_path) unless $LOAD_PATH.include?(lib_path)
          require @domain.gem_name
          Dir[File.join(lib_path, "**/*.rb")].sort.each { |f| require f }
        end
        @mod = Object.const_get(mod_name)
        @app = Runtime.new(@domain)
        @port = CommandBusPort.new(command_bus: @app.command_bus)
        @routes = RouteBuilder.new(@domain, @mod, port: @port).build
      end

      # Check if a route pattern matches a request path.
      #
      # Splits both pattern and path by "/" and compares segment by segment.
      # Pattern segments starting with ":" are treated as wildcards that
      # match any value.
      #
      # @param pattern [String] the route pattern (e.g. "/pizzas/:id")
      # @param path [String] the actual request path (e.g. "/pizzas/abc123")
      # @return [Boolean] true if the path matches the pattern
      def match?(pattern, path)
        pp = pattern.split("/"); ap = path.split("/")
        pp.size == ap.size && pp.zip(ap).all? { |p, a| p.start_with?(":") || p == a }
      end

      # Set CORS headers on the response to allow cross-origin requests.
      #
      # @param res [WEBrick::HTTPResponse] the response to add headers to
      # @return [void]
      def set_cors(res)
        res["Access-Control-Allow-Origin"] = "*"
        res["Access-Control-Allow-Methods"] = "GET, POST, PATCH, DELETE, OPTIONS"
        res["Access-Control-Allow-Headers"] = "Content-Type, X-CSRF-Token, Authorization"
      end

      # Wraps a WEBrick::HTTPRequest to provide a consistent interface
      # for route handlers, similar to Rack::Request. Exposes path, params,
      # body, and request_method.
      class RequestWrapper
        # @return [String] the request path (e.g. "/pizzas/abc123")
        attr_reader :path

        # @return [Hash] the parsed query string parameters
        attr_reader :params

        # Wrap a WEBrick request, extracting path and query params.
        #
        # @param req [WEBrick::HTTPRequest] the raw WEBrick request to wrap
        # @return [RequestWrapper] a new wrapper instance
        def initialize(req)
          @req = req
          @path = req.path
          @params = req.query
        end

        # Return the request body as a StringIO for consistent reading.
        #
        # Wraps the raw body string (or empty string if nil) in a StringIO
        # so handlers can call +.read+ regardless of the actual body type.
        #
        # @return [StringIO] the request body as a readable IO object
        def body
          ::StringIO.new(@req.body || "")
        end

        # Return the HTTP method of the request.
        #
        # @return [String] the HTTP method (e.g. "GET", "POST", "PATCH", "DELETE")
        def request_method
          @req.request_method
        end
      end
    end
  end
end
