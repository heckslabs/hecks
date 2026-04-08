# Hecks::Appeal::IdeServer
#
# WEBrick HTTP server for the HecksAppeal IDE. Serves static assets
# and delegates WebSocket transport to the runtime's :websocket
# capability. Domain commands flow through the runtime's command bus.
#
#   server = IdeServer.new(bridge, runtimes)
#   server.run
#
require "webrick"
require "json"

module Hecks
  module Appeal
    class IdeServer
      ASSETS_DIR = File.join(__dir__, "assets")
      VIEWS_DIR = File.join(__dir__, "views")

      def initialize(bridge, runtimes, port: 4567)
        @bridge = bridge
        @runtimes = runtimes
        @port = port
      end

      # Start the HTTP server and the WebSocket adapter.
      #
      # @return [void]
      def run
        puts "HecksAppeal IDE starting on http://localhost:#{@port}"
        puts ""

        @bridge.projects.each do |path, project|
          puts "  #{project[:name]}/"
          project[:domains]&.each do |d|
            puts "    #{d[:name]} (#{d[:aggregates]&.size || 0} aggregates)"
          end
        end
        puts ""

        ws_runtime = @runtimes.find { |rt| rt.respond_to?(:websocket) }
        if ws_runtime
          port = ws_runtime.websocket
          port.on_connect { |client| push_state(port, client) }
          ws_runtime.websocket_adapter.start_async
          puts "WebSocket on ws://localhost:#{ws_runtime.websocket_adapter.instance_variable_get(:@listen_port) rescue "?"}"
        end

        server = WEBrick::HTTPServer.new(
          Port: @port,
          Logger: WEBrick::Log.new($stderr, WEBrick::Log::WARN),
          AccessLog: []
        )

        server.mount_proc("/") { |req, res| handle_http(req, res) }

        trap("INT") { server.shutdown }

        puts "Open http://localhost:#{@port} in your browser"
        puts ""
        server.start
      end

      private

      def push_state(port, client)
        world = Hecks.respond_to?(:last_world) ? Hecks.last_world&.to_h : nil
        state = @bridge.to_state.merge(cwd: Dir.pwd, world: world)
        port.send_json(client, { type: "state", data: state })
      end

      def handle_http(req, res)
        case req.path
        when "/"
          serve_layout(res)
        when %r{^/assets/}
          serve_asset(req.path, res)
        else
          res.status = 404
          res.body = "Not found"
        end
      end

      def serve_layout(res)
        res["Content-Type"] = "text/html; charset=utf-8"
        res.body = File.read(File.join(VIEWS_DIR, "layout.html"))
      end

      def serve_asset(path, res)
        clean = path.sub(%r{^/assets/}, "")
        return not_found(res) if clean.include?("..")

        full_path = File.join(ASSETS_DIR, clean)
        return not_found(res) unless File.exist?(full_path)

        res["Content-Type"] = content_type(full_path)
        res["Cache-Control"] = "no-cache"
        res.body = File.read(full_path)
      end

      def not_found(res)
        res.status = 404
        res.body = "Not found"
      end

      def content_type(path)
        case File.extname(path)
        when ".css" then "text/css; charset=utf-8"
        when ".js"  then "application/javascript; charset=utf-8"
        when ".html" then "text/html; charset=utf-8"
        when ".svg" then "image/svg+xml"
        when ".png" then "image/png"
        else "application/octet-stream"
        end
      end
    end
  end
end
