require "webrick"
require "json"
require "stringio"
require "tmpdir"
require_relative "route_builder"
require_relative "cors_headers"
require_relative "command_bus_port"
require_relative "csrf_helpers"
require_relative "../auth/screen_routes"
require_relative "domain_watcher"

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
    # Supports hot reload via +--watch+ flag. When enabled, polls the domain
    # source directory for changes and rebuilds routes automatically.
    #
    #   hecks serve pizzas_domain
    #   hecks serve pizzas_domain --watch
    #
    class DomainServer
      include HecksTemplating::NamingHelpers
      include Hecks::HTTP::CorsHeaders
      include CsrfHelpers
      include Hecks::Auth::ScreenRoutes
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
      # @param watch [Boolean] whether to watch for domain source changes and
      #   hot-reload routes without restart (default: false)
      # @param watch_interval [Numeric] seconds between file polls when watch
      #   is enabled (default: 1)
      # @return [DomainServer] a new server instance ready to run
      def initialize(domain, port: 9292, live: false, live_port: 9293,
                     watch: false, watch_interval: 1)
        @domain = domain
        @port = port
        @live = live
        @live_port = live_port
        @watch = watch
        @watch_interval = watch_interval
        @sse_clients = []
        @lock = Mutex.new
        boot_domain
      end

      # Start the WEBrick HTTP server and begin handling requests.
      #
      # Prints the route table to stdout, optionally starts the WebSocket
      # server and file watcher, then enters the WEBrick event loop. Blocks
      # until the process receives an INT signal (Ctrl-C).
      #
      # @return [void]
      def run
        puts "Hecks serving #{@domain.name} on http://localhost:#{@port}"
        puts ""
        @lock.synchronize { @routes }.each { |r| puts "  #{r[:method].ljust(6)} #{r[:path]}" }
        puts "  GET    /login"
        puts "  POST   /login"
        puts "  GET    /signup"
        puts "  POST   /signup"
        puts "  GET    /logout"
        puts "  GET    /events (SSE)"
        puts "  GET    /_openapi"
        puts "  GET    /_schema"
        start_websocket_server if @live
        start_watcher if @watch
        puts ""

        server = WEBrick::HTTPServer.new(Port: @port, Logger: WEBrick::Log.new("/dev/null"), AccessLog: [])
        server.mount_proc("/") { |req, res| handle(req, res) }
        trap("INT") { @watcher&.stop; server.shutdown }
        server.start
      end

      # Reload the domain by re-reading the Bluebook source, rebuilding the
      # domain IR, and swapping routes. Thread-safe via mutex.
      #
      # @return [void]
      def reload!
        source = @domain.source_path
        return unless source && File.exist?(source)

        Kernel.load(source)
        new_domain = Hecks.last_domain
        new_domain.source_path = source
        @lock.synchronize do
          @domain = new_domain
          rebuild_routes
        end
        puts "[hecks] Domain reloaded at #{Time.now.strftime('%H:%M:%S')}"
      rescue => e
        warn "[hecks] Reload failed: #{e.message}"
      end

      private

      # Dispatch an incoming HTTP request to the appropriate route handler.
      #
      # Sets CORS headers on every response. Handles OPTIONS preflight
      # requests by returning immediately. Routes +/events+ to the event
      # history endpoint. For all other paths, finds a matching route and
      # delegates to its handler lambda. Thread-safe via mutex on route access.
      #
      # @param req [WEBrick::HTTPRequest] the incoming HTTP request
      # @param res [WEBrick::HTTPResponse] the outgoing HTTP response
      # @return [void]
      def handle(req, res)
        set_cors(res)
        return if req.request_method == "OPTIONS"

        restore_actor_from_session(req)

        if auth_route?(req.path)
          handle_auth_route(req, res)
          return
        end

        if csrf_required?(req) && !valid_csrf_json?(req)
          res.status = 403
          res["Content-Type"] = "application/json"
          res.body = JSON.generate(error: "CSRF token mismatch")
          return
        end

        app, domain, routes = @lock.synchronize { [@app, @domain, @routes] }

        if req.path == "/events"
          res["Content-Type"] = "application/json"
          res.body = JSON.generate(app.events.map { |e| { type: Hecks::Utils.const_short_name(e), occurred_at: e.occurred_at.iso8601 } })
          return
        end

        if req.path == "/_openapi"
          res["Content-Type"] = "application/json"
          res.body = JSON.generate(Hecks::HTTP::OpenapiGenerator.new(domain).generate)
          return
        end

        if req.path == "/_schema"
          res["Content-Type"] = "application/json"
          res.body = JSON.generate(Hecks::HTTP::JsonSchemaGenerator.new(domain).generate)
          return
        end

        route = routes.find { |r| r[:method] == req.request_method && route_matches_request_path?(r[:path], req.path) }
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

      # Restore the actor from the session cookie if present.
      #
      # @param req [WEBrick::HTTPRequest] the incoming request
      # @return [void]
      def restore_actor_from_session(req)
        actor = restore_session(req)
        Hecks.actor = actor if actor
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

      # Start the file watcher for hot reload.
      #
      # Resolves the domain source directory from the domain's source_path,
      # then starts a DomainWatcher that calls reload! on change.
      #
      # @return [void]
      def start_watcher
        watch_dir = resolve_watch_dir
        unless watch_dir
          warn "[hecks] No source_path on domain — cannot watch for changes"
          return
        end
        puts "  Watching #{watch_dir} for changes..."
        @watcher = DomainWatcher.new(watch_dir, interval: @watch_interval) { reload! }
        @watcher.start
      end

      # Resolve the directory to watch from the domain's source_path.
      #
      # @return [String, nil] the directory containing domain source files
      def resolve_watch_dir
        return nil unless @domain.source_path

        path = @domain.source_path
        File.directory?(path) ? path : File.dirname(path)
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
        rebuild_routes
      end

      # Rebuild the runtime and routes from the current @domain.
      # Called from boot_domain and reload!. Caller must hold @lock
      # when called from reload!.
      #
      # @return [void]
      def rebuild_routes
        @app = Runtime.new(@domain)
        bus_port = CommandBusPort.new(command_bus: @app.command_bus)
        @routes = RouteBuilder.new(@domain, @mod, port: bus_port).build
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
      def route_matches_request_path?(pattern, path)
        pp = pattern.split("/"); ap = path.split("/")
        pp.size == ap.size && pp.zip(ap).all? { |p, a| p.start_with?(":") || p == a }
      end

      # Set CORS headers on the response using ENV-driven origin config.
      #
      # Delegates to {Hecks::HTTP::CorsHeaders#apply_cors_origin} which
      # checks HECKS_ALLOW_ALL_ORIGINS and HECKS_CORS_ORIGIN env vars.
      #
      # @param res [WEBrick::HTTPResponse] the response to add headers to
      # @return [void]
      def set_cors(res)
        apply_cors_origin(res)
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
