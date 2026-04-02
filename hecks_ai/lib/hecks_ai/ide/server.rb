# Hecks::AI::IDE::Server
#
# WEBrick server for the Hecks IDE. Streams Claude responses via
# poll-based JSON events, accepts prompts via POST.
#
#   Server.new(project_dir: Dir.pwd, port: 3001).run
#
require "webrick"
require "json"
require "base64"
require "fileutils"
require_relative "claude_process"
require_relative "bluebook_discovery"
require_relative "context_builder"

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
          when ["GET", "/context"]    then serve_context(res)
          when ["POST", "/prompt"]    then handle_prompt(req, res)
          when ["GET", "/bluebooks"]   then serve_bluebooks(res)
          when ["POST", "/interrupt"] then handle_interrupt(res)
          when ["POST", "/screenshot"] then handle_screenshot(req, res)
          else
            if req.request_method == "GET" && req.path.start_with?("/file/")
              serve_file(req, res)
            else
              res.status = 404; res.body = "Not found"
            end
          end
        end

        def serve_page(res)
          res.content_type = "text/html"
          res.body = File.read(File.join(VIEWS_DIR, "ide.html"))
        end

        def serve_events(req, res)
          after = (req.query["after"] || "0").to_i
          events, total = @mutex.synchronize do
            # Client is ahead of the array — a reset happened
            if after > @events.size
              return serve_reset(res)
            end
            [@events[after..] || [], @events.size]
          end
          res.content_type = "application/json"
          res["Cache-Control"] = "no-cache"
          res.body = JSON.generate(events: events, next_index: after + events.size)
        end

        def serve_reset(res)
          res.content_type = "application/json"
          res["Cache-Control"] = "no-cache"
          res.body = JSON.generate(events: ['{"type":"reload"}'], next_index: 0)
        end

        def handle_prompt(req, res)
          body = JSON.parse(req.body)
          prompt = body["prompt"]

          context_json = JSON.pretty_generate(build_context)

          file_ctx = body["file_context"]
          if file_ctx
            prompt = "#{prompt}\n\n[User is viewing #{file_ctx} in the IDE — reference it directly without needing the filename]"
          end

          if @latest_screenshot
            prompt = "#{prompt}\n\n[IDE screenshot at #{@latest_screenshot} — use Read to view it]\n\n[IDE context]\n#{context_json}"
          else
            prompt = "#{prompt}\n\n[IDE context]\n#{context_json}"
          end

          @claude ||= ClaudeProcess.new(project_dir: @project_dir) do |json|
            @mutex.synchronize { @events << json }
          end
          @claude.send_prompt(prompt)
          res.content_type = "application/json"
          res.body = JSON.generate(ok: true)
        rescue JSON::ParserError => e
          res.status = 400
          res.body = JSON.generate(error: e.message)
        end

        def serve_context(res)
          ctx = ContextBuilder.new(@project_dir).build
          res.content_type = "application/json"
          res["Cache-Control"] = "no-cache"
          res.body = JSON.generate(ctx)
        end

        def build_context
          ContextBuilder.new(@project_dir).build
        end

        def serve_bluebooks(res)
          discovery = BluebookDiscovery.new(@project_dir)
          res.content_type = "application/json"
          res["Cache-Control"] = "no-cache"
          res.body = JSON.generate(discovery.apps)
        end

        def serve_file(req, res)
          rel = req.path.sub("/file/", "")
          path = File.join(@project_dir, rel)
          unless File.exist?(path) && path.start_with?(@project_dir)
            res.status = 404; res.body = "File not found"; return
          end
          res.content_type = "text/plain; charset=utf-8"
          res.body = File.read(path)
        end

        def handle_screenshot(req, res)
          body = JSON.parse(req.body)
          save_screenshot(Base64.decode64(body["data"]))
          res.content_type = "application/json"
          res.body = JSON.generate(ok: true)
        rescue => e
          res.status = 400
          res.body = JSON.generate(error: e.message)
        end

        def save_screenshot(png_data)
          dir = File.join(@project_dir, ".claude", "ide", "screenshots")
          FileUtils.mkdir_p(dir)
          ts = Time.now.strftime("%Y%m%d_%H%M%S")
          path = File.join(dir, "#{ts}.png")
          File.binwrite(path, png_data)
          # Also write latest for quick access
          File.binwrite(File.join(dir, "latest.png"), png_data)
          # Keep last 20
          shots = Dir[File.join(dir, "*.png")].reject { |f| f.end_with?("latest.png") }.sort
          shots[0...-20].each { |f| File.delete(f) } if shots.size > 20
          @latest_screenshot = path
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
