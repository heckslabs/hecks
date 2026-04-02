# Hecks::AI::IDE::SessionDiscovery
#
# Lists recent Claude Code sessions for the current project.
# Reads JSONL session files and extracts preview text.
#
#   discovery = SessionDiscovery.new("/path/to/project")
#   discovery.recent  # => [{ id: "abc-123", age: "5m", preview: "..." }]
#
require "json"

module Hecks
  module AI
    module IDE
      class SessionDiscovery
        CLAUDE_PROJECTS = File.join(Dir.home, ".claude", "projects")

        def initialize(project_dir)
          @project_dir = File.expand_path(project_dir)
        end

        def recent(limit: 20)
          dir = session_dir
          return [] unless dir && File.directory?(dir)

          Dir[File.join(dir, "*.jsonl")]
            .sort_by { |f| -File.mtime(f).to_f }
            .first(limit)
            .map { |f| build_entry(f) }
        end

        private

        def session_dir
          encoded = @project_dir.tr("/", "-")
          path = File.join(CLAUDE_PROJECTS, encoded)
          File.directory?(path) ? path : nil
        end

        def build_entry(path)
          id = File.basename(path, ".jsonl")
          age = format_age(Time.now - File.mtime(path))
          preview = extract_preview(path)
          { id: id, age: age, preview: preview, updated_at: File.mtime(path).iso8601 }
        end

        def extract_preview(path)
          File.foreach(path) do |line|
            data = JSON.parse(line) rescue next
            next unless data["type"] == "user"
            msg = data["message"]
            text = case msg
                   when Hash then msg["content"]
                   when String then msg
                   end
            text = text.first["text"] if text.is_a?(Array)
            next unless text.is_a?(String)
            # Strip IDE context appended to prompts
            clean = text.split("\n\n[IDE").first.strip
            return clean[0..80] unless clean.empty?
          end
          "(no preview)"
        rescue
          "(unreadable)"
        end

        def format_age(seconds)
          if seconds < 60 then "now"
          elsif seconds < 3600 then "#{(seconds / 60).round}m"
          elsif seconds < 86400 then "#{(seconds / 3600).round}h"
          else "#{(seconds / 86400).round}d"
          end
        end
      end
    end
  end
end
