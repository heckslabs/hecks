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
require_relative "bluebook_discovery"
require_relative "context_builder"
# workshop_session loaded lazily when a domain is opened
require_relative "screenshot_handler"
require_relative "view_watcher"
require_relative "prompt_builder"

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
          @workshop = nil
          @screenshots = ScreenshotHandler.new(project_dir)
          @prompt_builder = PromptBuilder.new(ContextBuilder.new(project_dir), @screenshots)
        end

        def run
          http = WEBrick::HTTPServer.new(
            Port: @port,
            Logger: WEBrick::Log.new($stderr, WEBrick::Log::WARN),
            AccessLog: []
          )
          http.mount_proc("/") { |req, res| route(req, res) }
          trap("INT") { @claude&.stop; http.shutdown }
          ViewWatcher.new(VIEWS_DIR, @events, @mutex).start
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
          when ["GET", "/bluebooks"]          then serve_bluebooks(res)
          when ["POST", "/workshop/open"]    then handle_workshop_open(req, res)
          when ["POST", "/workshop/command"] then handle_workshop_command(req, res)
          when ["GET", "/workshop/state"]    then serve_workshop_state(res)
          when ["POST", "/interrupt"]        then handle_interrupt(res)
          when ["POST", "/console"]         then handle_console(req, res)
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
          res["Cache-Control"] = "no-cache, no-store"
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
          prompt = @prompt_builder.build(body["prompt"], file_context: body["file_context"])

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
          res.content_type = "application/json"
          res["Cache-Control"] = "no-cache"
          res.body = JSON.generate(ContextBuilder.new(@project_dir).build)
        end

        def handle_workshop_open(req, res)
          body = JSON.parse(req.body)
          require "hecks"
          require_relative "workshop_session"
          @workshop = WorkshopSession.new(body["path"], project_dir: @project_dir)
          res.content_type = "application/json"
          res.body = JSON.generate(
            domain: @workshop.domain_name,
            state: @workshop.state,
            completions: @workshop.completions,
            diagram: @workshop.diagram
          )
        end

        def handle_workshop_command(req, res)
          body = JSON.parse(req.body)
          unless @workshop
            res.status = 400
            res.body = JSON.generate(error: "No workshop session. Open a domain first.")
            return
          end
          result = @workshop.execute(body["command"])
          res.content_type = "application/json"
          res.body = JSON.generate(
            output: result[:output], error: result[:error],
            state: @workshop.state, completions: @workshop.completions
          )
        end

        def serve_workshop_state(res)
          res.content_type = "application/json"
          res["Cache-Control"] = "no-cache"
          if @workshop
            res.body = JSON.generate(
              domain: @workshop.domain_name,
              state: @workshop.state,
              completions: @workshop.completions
            )
          else
            res.body = JSON.generate(domain: nil)
          end
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
          @screenshots.save(body["data"])
          res.content_type = "application/json"
          res.body = JSON.generate(ok: true)
        rescue => e
          res.status = 400
          res.body = JSON.generate(error: e.message)
        end

        def handle_console(req, res)
          body = JSON.parse(req.body)
          $stderr.puts "[IDE JS] #{body["level"]}: #{body["message"]}"
          res.content_type = "application/json"
          res.body = JSON.generate(ok: true)
        rescue => e
          res.status = 400
          res.body = e.message
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
