# Hecks::AI::IDE::Server
#
# WEBrick server for the Hecks IDE. Streams Claude responses via
# poll-based JSON events, accepts prompts via POST.
#
#   Server.new(project_dir: Dir.pwd, port: 3001).run
#
require "webrick"
require "json"
require_relative "claude_process"

module Hecks
  module AI
    module IDE
      class Server
        VIEWS_DIR = File.join(__dir__, "views")

        def initialize(project_dir: Dir.pwd, port: 3001)
          @project_dir = project_dir
          @port = port
          @claude = nil
          @events = []
          @mutex = Mutex.new
        end

        def run
          http = WEBrick::HTTPServer.new(
            Port: @port,
            Logger: WEBrick::Log.new($stderr, WEBrick::Log::WARN),
            AccessLog: []
          )
          http.mount_proc("/") { |req, res| route(req, res) }
          trap("INT") { @claude&.stop; http.shutdown }
          Thread.new { sleep 0.5; open_browser("http://localhost:#{@port}") }
          puts "Hecks IDE: http://localhost:#{@port}"
          http.start
        end

        private

        def route(req, res)
          case [req.request_method, req.path]
          when ["GET", "/"]           then serve_page(res)
          when ["GET", "/events"]     then serve_events(req, res)
          when ["POST", "/prompt"]    then handle_prompt(req, res)
          when ["POST", "/interrupt"] then handle_interrupt(res)
          else res.status = 404; res.body = "Not found"
          end
        end

        def serve_page(res)
          res.content_type = "text/html"
          res.body = File.read(File.join(VIEWS_DIR, "ide.html"))
        end

        def serve_events(req, res)
          after = (req.query["after"] || "0").to_i
          events = @mutex.synchronize { @events[after..] || [] }
          res.content_type = "application/json"
          res["Cache-Control"] = "no-cache"
          res.body = JSON.generate(events: events, next_index: after + events.size)
        end

        def handle_prompt(req, res)
          body = JSON.parse(req.body)
          @claude ||= ClaudeProcess.new(project_dir: @project_dir) do |json|
            @mutex.synchronize { @events << json }
          end
          @claude.send_prompt(body["prompt"])
          res.content_type = "application/json"
          res.body = JSON.generate(ok: true)
        rescue JSON::ParserError => e
          res.status = 400
          res.body = JSON.generate(error: e.message)
        end

        def handle_interrupt(res)
          @claude&.interrupt!
          res.content_type = "application/json"
          res.body = JSON.generate(ok: true)
        end

        def open_browser(url)
          system("open #{url} 2>/dev/null") ||
            system("xdg-open #{url} 2>/dev/null")
        end
      end
    end
  end
end
