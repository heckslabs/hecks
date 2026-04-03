# Hecks::AI::IDE::SessionWatcher
#
# Tails a Claude session JSONL file and emits new messages as IDE events.
# User and assistant messages from the terminal show up in the browser.
#
#   watcher = SessionWatcher.new("abc-123", events, mutex, session_dir: dir)
#   watcher.start   # background thread
#   watcher.stop
#
require "json"

module Hecks
  module AI
    module IDE
      class SessionWatcher
        attr_reader :session_id

        def initialize(session_id, events, mutex, session_dir:)
          @session_id = session_id
          @events = events
          @mutex = mutex
          @path = File.join(session_dir, "#{session_id}.jsonl")
          @stop = false
          @thread = nil
          @ide_prompt_at = nil
        end

        def start
          return unless File.exist?(@path)
          @stop = false
          @thread = Thread.new { tail_loop }
        end

        def stop
          @stop = true
          @thread&.join(2)
          @thread = nil
        end

        def watching?
          @thread&.alive? || false
        end

        def mark_ide_prompt!
          @ide_prompt_at = Time.now
        end

        private

        def tail_loop
          File.open(@path, "r") do |f|
            f.seek(0, IO::SEEK_END)
            buf = ""
            until @stop
              chunk = f.read(4096)
              if chunk
                buf += chunk
                while (idx = buf.index("\n"))
                  line = buf.slice!(0..idx).strip
                  process_line(line) unless line.empty?
                end
              else
                sleep 0.3
              end
            end
          end
        rescue => e
          emit(JSON.generate(type: "error", message: "Watcher: #{e.message}"))
        end

        def process_line(line)
          data = JSON.parse(line) rescue return
          type = data["type"]
          case type
          when "assistant"
            emit(line)
          when "user"
            msg = data["message"]
            emit_tool_results(msg)
            return if ide_prompt_recent?
            emit(JSON.generate(type: "user_echo", message: msg))
          when "result"
            emit(line)
          end
        end

        def emit_tool_results(msg)
          return unless msg.is_a?(Hash)
          content = msg["content"]
          return unless content.is_a?(Array)
          content.each do |c|
            next unless c["type"] == "tool_result"
            text = extract_tool_text(c["content"])
            next if text.nil? || text.empty?
            emit(JSON.generate(type: "tool_result", tool_use_id: c["tool_use_id"], output: text))
          end
        end

        def extract_tool_text(content)
          case content
          when String then content
          when Array
            content.select { |c| c["type"] == "text" }.map { |c| c["text"] }.join
          end
        end

        def ide_prompt_recent?
          @ide_prompt_at && (Time.now - @ide_prompt_at) < 30
        end

        def emit(json)
          @mutex.synchronize { @events << json }
        end
      end
    end
  end
end
