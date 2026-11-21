# frozen_string_literal: true

require "json"
require "time"

module Hecks
  module Adapters
    class Metering
      # Reads the usage the session transcripts already record, one row per assistant message,
      # never by booting a domain. A transcript is read again only when its size or time
      # changed, and a message it repeats across its lines is counted once.
      class TokenTranscripts
        # @param projects [String] where Claude files each directory's transcripts
        def initialize(projects: File.join(Dir.home, ".claude", "projects"))
          @projects = projects
          @memo = {}
        end

        # @return [Array<Hash>] `session:`, `day:`, `model:`, `input:`, `output:`,
        #   `cache_creation:` and `cache_read:` for each message of each transcript
        def call
          Dir.glob(File.join(@projects, "*", "*.jsonl")).flat_map { |path| rows(path) }
        rescue SystemCallError
          []
        end

        private

        def rows(path)
          stat = File.stat(path)
          stamp = [stat.mtime, stat.size]
          held = @memo[path]
          return held[:rows] if held && held[:stamp] == stamp

          (@memo[path] = { stamp: stamp, rows: read(path) })[:rows]
        rescue SystemCallError
          []
        end

        def read(path)
          session = File.basename(path, ".jsonl")
          messages = File.foreach(path).filter_map { |line| parse(line) }.uniq { |row| row[:id] }
          messages.map { |row| row.merge(session: session) }
        end

        def parse(line)
          return unless line.include?('"usage"')

          entry = JSON.parse(line)
          message = entry["message"]
          row(entry, message) if message.is_a?(Hash) && message["usage"].is_a?(Hash)
        rescue JSON::ParserError
          nil
        end

        def row(entry, message)
          usage = message["usage"]
          { id: message["id"] || entry["uuid"], day: entry["timestamp"].to_s[0, 10], model: message["model"].to_s,
            input: usage["input_tokens"].to_i, output: usage["output_tokens"].to_i,
            cache_creation: usage["cache_creation_input_tokens"].to_i, cache_read: usage["cache_read_input_tokens"].to_i }
        end
      end
    end
  end
end
