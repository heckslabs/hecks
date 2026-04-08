# Hecks::Capabilities::StaticAssets::Adapter
#
# Default HTTP transport adapter using WEBrick. Mounts routes
# that delegate to the port for file lookup and content-type
# resolution. Other capabilities can mount additional routes
# via the mount method before the server starts.
#
#   adapter = StaticAssets::Adapter.new(port)
#   adapter.mount("/hecks/docs") { |req, res| res.body = "..." }
#   adapter.start
#
require "webrick"

module Hecks
  module Capabilities
    module StaticAssets
      # Hecks::Capabilities::StaticAssets::Adapter
      #
      # Default WEBrick transport with extensible routing.
      #
      class Adapter
        def initialize(port)
          @port = port
          @extra_routes = {}
        end

        # Mount an additional route on the HTTP server.
        # Must be called before start.
        #
        # @param path [String] URL path (e.g. "/hecks/docs")
        # @yield [req, res] WEBrick request handler
        def mount(path, &handler)
          @extra_routes[path] = handler
        end

        # Start serving. Blocks the calling thread.
        def start
          @server = build_server
          trap("INT") { @server.shutdown }
          @server.start
        end

        # Start in a background thread.
        #
        # @return [Thread]
        def start_async
          Thread.new { start }
        end

        private

        def build_server
          server = WEBrick::HTTPServer.new(
            Port: @port.listen_port,
            Logger: WEBrick::Log.new($stderr, WEBrick::Log::WARN),
            AccessLog: []
          )

          # Extra routes first (more specific paths)
          @extra_routes.each do |path, handler|
            server.mount_proc(path) { |req, res| handler.call(req, res) }
          end

          mount_assets(server)
          mount_layout(server)
          server
        end

        def mount_layout(server)
          port = @port
          server.mount_proc("/") do |_req, res|
            content = port.serve_layout
            if content
              res.status = 200
              res["Content-Type"] = "text/html"
              res.body = content
            else
              res.status = 404
              res.body = "layout.html not found"
            end
          end
        end

        def mount_assets(server)
          port = @port
          server.mount_proc("/assets") do |req, res|
            relative = req.path.sub(%r{^/assets/?}, "")
            result = port.serve_asset(relative)
            if result
              res.status = 200
              res["Content-Type"] = result[:content_type]
              res.body = result[:content]
            else
              res.status = 404
              res.body = "Asset not found: #{relative}"
            end
          end
        end
      end
    end
  end
end
