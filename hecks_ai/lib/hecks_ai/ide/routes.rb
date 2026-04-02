# Hecks::AI::IDE::Routes
#
# HTTP route dispatch for the IDE server. Each route method handles
# one endpoint. Extracted from Server to keep it under 200 lines.
#
module Hecks
  module AI
    module IDE
      module Routes
        def serve_page(res)
          res.content_type = "text/html"
          res["Cache-Control"] = "no-cache, no-store"
          res.body = File.read(File.join(self.class::VIEWS_DIR, "ide.html"))
        end

        def serve_js(res)
          res.content_type = "application/javascript"
          res["Cache-Control"] = "no-cache, no-store"
          js_dir = File.join(self.class::VIEWS_DIR, "js")
          files = %w[ide.js panels.js components.js autocomplete.js app_picker.js
                     session_picker.js command_log.js markdown.js file_viewer.js
                     hecksagon_viewer.js bluebook_explorer.js workshop.js boot.js]
          res.body = files.map { |f| File.read(File.join(js_dir, f)) }.join("\n")
        end

        def serve_events(req, res)
          after = (req.query["after"] || "0").to_i
          events, total = @mutex.synchronize do
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

        def serve_context(res)
          res.content_type = "application/json"
          res["Cache-Control"] = "no-cache"
          res.body = JSON.generate(ContextBuilder.new(@project_dir).build)
        end

        def serve_bluebooks(res)
          discovery = BluebookDiscovery.new(@project_dir)
          res.content_type = "application/json"
          res["Cache-Control"] = "no-cache"
          res.body = JSON.generate(discovery.apps)
        end

        def serve_sessions(res)
          sessions = SessionDiscovery.new(@project_dir).recent
          res.content_type = "application/json"
          res["Cache-Control"] = "no-cache"
          res.body = JSON.generate(sessions: sessions)
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

        def handle_interrupt(res)
          @claude&.interrupt!
          res.content_type = "application/json"
          res.body = JSON.generate(ok: true)
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

        def handle_bus_emit(req, res)
          body = JSON.parse(req.body)
          event = JSON.generate(type: "bus", event: body["event"], data: body["data"])
          @mutex.synchronize { @events << event }
          res.content_type = "application/json"
          res.body = JSON.generate(ok: true)
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

        def handle_session_resume(req, res)
          body = JSON.parse(req.body)
          session_id = body["session_id"]
          @claude&.stop
          @claude = ClaudeProcess.new(project_dir: @project_dir) do |json|
            @mutex.synchronize { @events << json }
          end
          @claude.resume(session_id)
          res.content_type = "application/json"
          res.body = JSON.generate(ok: true, session_id: session_id)
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
            res.body = JSON.generate(error: "No workshop session.")
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
      end
    end
  end
end
