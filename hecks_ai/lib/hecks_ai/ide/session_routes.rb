# Hecks::AI::IDE::SessionRoutes
#
# HTTP route handlers for session management: resume, disconnect,
# history, and JSONL message extraction.
#
#   include SessionRoutes  # mixed into Routes
#
require "json"

module Hecks
  module AI
    module IDE
      module SessionRoutes
        def handle_session_resume(req, res)
          body = JSON.parse(req.body)
          session_id = body["session_id"]
          @claude&.stop
          @watcher&.stop
          @claude = ClaudeProcess.new(project_dir: @project_dir) do |json|
            @mutex.synchronize { @events << json }
          end
          @claude.resume(session_id)
          session_dir = SessionDiscovery.new(@project_dir).send(:session_dir)
          if session_dir
            @watcher = SessionWatcher.new(session_id, @events, @mutex, session_dir: session_dir)
            @watcher.start
          end
          res.content_type = "application/json"
          res.body = JSON.generate(ok: true, session_id: session_id, watching: @watcher&.watching?)
        end

        def handle_session_reset(res)
          @claude&.stop
          @claude = nil
          @watcher&.stop
          @watcher = nil
          @mutex.synchronize { @events.clear }
          res.content_type = "application/json"
          res.body = JSON.generate(ok: true)
        end

        def serve_session_history(req, res)
          session_id = req.query["session_id"]
          limit = (req.query["limit"] || "30").to_i
          dir = SessionDiscovery.new(@project_dir).send(:session_dir)
          path = dir && File.join(dir, "#{session_id}.jsonl")
          unless path && File.exist?(path)
            res.content_type = "application/json"
            res.body = JSON.generate(turns: [])
            return
          end
          turns = []
          File.foreach(path) do |line|
            data = JSON.parse(line) rescue next
            case data["type"]
            when "user"
              text = extract_message_text(data["message"])
              next if text.nil? || text.empty?
              turns << { role: "user", text: text }
            when "assistant"
              text = extract_assistant_text(data["message"])
              next if text.nil? || text.empty?
              if turns.last&.dig(:role) == "assistant"
                turns.last[:text] += text
              else
                turns << { role: "assistant", text: text }
              end
            end
          end
          res.content_type = "application/json"
          res.body = JSON.generate(turns: turns.last(limit))
        end

        private

        def extract_message_text(msg)
          case msg
          when String then msg
          when Hash
            content = msg["content"]
            case content
            when String then content
            when Array
              content
                .select { |c| c["type"] == "text" }
                .map { |c| c["text"] }
                .compact.join
            end
          end
        end

        def extract_assistant_text(msg)
          return unless msg.is_a?(Hash) && msg["content"].is_a?(Array)
          msg["content"].select { |c| c["type"] == "text" }.map { |c| c["text"] }.join
        end
      end
    end
  end
end
