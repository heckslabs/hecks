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
require_relative "screenshot_handler"
require_relative "session_discovery"
require_relative "view_watcher"
require_relative "prompt_builder"
require_relative "routes"

module Hecks
  module AI
    module IDE
      class Server
        include Routes

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
          ViewWatcher.new(VIEWS_DIR, @events, @mutex, screenshot_handler: @screenshots).start
          # Thread.new { sleep 0.5; open_browser("http://localhost:#{@port}") }
          puts "Hecks IDE: http://localhost:#{@port}"
          http.start
        end

        private

        def route(req, res)
          case [req.request_method, req.path]
          when ["GET", "/"]                  then serve_page(res)
          when ["GET", "/ide.js"]            then serve_js(res)
          when ["GET", "/events"]            then serve_events(req, res)
          when ["GET", "/context"]           then serve_context(res)
          when ["GET", "/bluebooks"]         then serve_bluebooks(res)
          when ["GET", "/docs"]              then serve_docs(res)
          when ["GET", "/sessions"]          then serve_sessions(res)
          when ["POST", "/prompt"]           then handle_prompt(req, res)
          when ["POST", "/workshop/open"]    then handle_workshop_open(req, res)
          when ["POST", "/workshop/command"] then handle_workshop_command(req, res)
          when ["GET", "/workshop/state"]    then serve_workshop_state(res)
          when ["POST", "/session/resume"]   then handle_session_resume(req, res)
          when ["POST", "/interrupt"]        then handle_interrupt(res)
          when ["POST", "/screenshot"]       then handle_screenshot(req, res)
          when ["POST", "/console"]          then handle_console(req, res)
          when ["GET", "/console/log"]       then serve_console_log(res)
          when ["POST", "/bus"]              then handle_bus_emit(req, res)
          else
            if req.request_method == "GET" && req.path.start_with?("/file/")
              serve_file(req, res)
            else
              res.status = 404; res.body = "Not found"
            end
          end
        end

        def open_browser(url)
          system("open #{url} 2>/dev/null") ||
            system("xdg-open #{url} 2>/dev/null")
        end
      end
    end
  end
end
