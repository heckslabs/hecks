# Hecks::CLI::DocumentationServer
#
# WEBrick server that serves a domain as executable documentation.
# Boots a .bluebook file, walks the IR, and serves JSON + HTML.
# The Documentation concern in action: WebStack + DomainPresentation.
#
#   server = DocumentationServer.new("pizzas.bluebook", port: 4567)
#   server.run
#
require "webrick"
require "json"
require "hecks_cli/documentation_server/domain_serializer"

module Hecks
  class CLI
    class DocumentationServer
      VIEWS_DIR = File.join(__dir__, "documentation_server", "views")

      def initialize(bluebook_path, port: 4567)
        @path = bluebook_path
        @port = port
        @sse_clients = []
        @sse_mutex = Mutex.new
      end

      def run
        @domain = boot_domain
        @serialized = DomainSerializer.new(@domain).call
        start_server
      end

      private

      def boot_domain
        Hecks::DSL::AggregateBuilder::VoTypeResolution.with_vo_constants do
          Kernel.load(File.expand_path(@path))
        end
        Hecks.last_domain
      end

      def start_server
        server = WEBrick::HTTPServer.new(
          Port: @port,
          Logger: WEBrick::Log.new($stderr, WEBrick::Log::WARN),
          AccessLog: []
        )
        server.mount_proc("/") { |req, res| handle(req, res) }
        trap("INT") { server.shutdown }
        url = "http://localhost:#{@port}"
        puts "Hecks Documentation: #{url}"
        system("open", url)
        server.start
      end

      def handle(req, res)
        case [req.request_method, req.path]
        when ["GET",  "/"]           then serve_html(res)
        when ["GET",  "/api/domain"] then serve_domain_json(res)
        when ["POST", "/api/dispatch"] then serve_dispatch(req, res)
        when ["GET",  "/api/events"] then serve_sse(req, res)
        else
          if req.request_method == "GET" && req.path.start_with?("/api/records/")
            serve_records(req, res)
          else
            res.status = 404
            res.body = "Not found"
          end
        end
      end

      def serve_html(res)
        res.content_type = "text/html; charset=utf-8"
        res["Cache-Control"] = "no-cache, no-store"
        res.body = File.read(File.join(VIEWS_DIR, "index.html"))
      end

      def serve_domain_json(res)
        res.content_type = "application/json"
        res["Cache-Control"] = "no-cache"
        res.body = JSON.generate(@serialized)
      end

      def serve_dispatch(req, res)
        body = JSON.parse(req.body)
        agg_name = body["aggregate"]
        cmd_name = body["command"]
        payload  = body["payload"] || {}
        result = execute_command(agg_name, cmd_name, payload)
        broadcast_event(cmd_name, agg_name, result)
        res.content_type = "application/json"
        res.body = JSON.generate(result)
      rescue => e
        res.status = 400
        res.content_type = "application/json"
        res.body = JSON.generate(error: "#{e.class}: #{e.message}")
      end

      def execute_command(agg_name, cmd_name, payload)
        { status: "ok", aggregate: agg_name, command: cmd_name, payload: payload }
      end

      def serve_records(req, res)
        agg_name = req.path.sub("/api/records/", "")
        agg = @serialized[:aggregates]&.find { |a| a[:name] == agg_name }
        records = agg ? (agg[:fixtures] || []) : []
        res.content_type = "application/json"
        res.body = JSON.generate(records: records)
      end

      def serve_sse(_req, res)
        res.content_type = "text/event-stream"
        res["Cache-Control"] = "no-cache"
        res["Connection"] = "keep-alive"
        res["X-Accel-Buffering"] = "no"
        queue = ::Queue.new
        @sse_mutex.synchronize { @sse_clients << queue }
        res.chunked = true
        res.body = proc do |socket|
          begin
            socket.write("data: {\"type\":\"connected\"}\n\n")
            loop do
              data = queue.pop
              socket.write("data: #{data}\n\n")
            end
          rescue IOError, Errno::EPIPE
            # client disconnected
          ensure
            @sse_mutex.synchronize { @sse_clients.delete(queue) }
          end
        end
      end

      def broadcast_event(command, aggregate, result)
        data = JSON.generate(command: command, aggregate: aggregate, result: result, timestamp: Time.now.iso8601)
        @sse_mutex.synchronize do
          @sse_clients.each { |q| q << data }
        end
      end
    end
  end
end
