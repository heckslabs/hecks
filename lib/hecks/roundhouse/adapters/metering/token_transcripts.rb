# frozen_string_literal: true

require "json"
require "time"
require_relative "trigger_kinds"

module Hecks
  module Adapters
    class Metering
      # Reads the usage the session transcripts already record, one row per assistant message (a
      # turn), never by booting a domain. A transcript is read again only when its size or time
      # changed, and a message it repeats across its lines is counted once. Each row carries the
      # context the turn re-read and the label of the prompt that set it going, never the prompt.
      class TokenTranscripts
        # @param projects [String] where Claude files each directory's transcripts
        def initialize(projects: File.join(Dir.home, ".claude", "projects"))
          @projects = projects
          @memo = {}
        end

        # @return [Array<Hash>] `session:`, `day:`, `model:`, `input:`, `output:`,
        #   `cache_creation:`, `cache_read:`, `context:` (the tokens the turn read in) and
        #   `trigger:` (a {TriggerKinds} label) for each message of each transcript
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
          trigger = TriggerKinds::OTHER
          messages = File.foreach(path).filter_map do |line|
            trigger = prompt(line) || trigger
            parse(line, trigger)
          end
          messages.uniq { |row| row[:id] }.map { |row| row.merge(session: session) }
        end

        # The label of the prompt a user line carries, nil for any other line or a tool result.
        def prompt(line)
          return unless line.include?('"type":"user"')

          entry = JSON.parse(line)
          text = text_of(entry.dig("message", "content"))
          TriggerKinds.label(text, typed: entry.dig("origin", "kind") == "human") unless text.empty?
        rescue JSON::ParserError
          nil
        end

        def text_of(content)
          return content.to_s unless content.is_a?(Array)

          content.filter_map { |part| part["text"] if part.is_a?(Hash) && part["type"] == "text" }.join
        end

        def parse(line, trigger)
          return unless line.include?('"usage"')

          entry = JSON.parse(line)
          message = entry["message"]
          row(entry, message, trigger) if message.is_a?(Hash) && message["usage"].is_a?(Hash)
        rescue JSON::ParserError
          nil
        end

        def row(entry, message, trigger)
          counts = counts(message["usage"])
          { id: message["id"] || entry["uuid"], day: entry["timestamp"].to_s[0, 10], model: message["model"].to_s,
            **counts, context: counts[:input] + counts[:cache_creation] + counts[:cache_read], trigger: trigger }
        end

        def counts(usage)
          { input: usage["input_tokens"].to_i, output: usage["output_tokens"].to_i,
            cache_creation: usage["cache_creation_input_tokens"].to_i, cache_read: usage["cache_read_input_tokens"].to_i }
        end
      end
    end
  end
end
