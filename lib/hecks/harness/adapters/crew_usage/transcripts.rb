# frozen_string_literal: true

require "json"
require "time"

module Hecks
  module Adapters
    class CrewUsage
      # The model calls of the session transcripts inside one window, read and never written. A
      # session's transcript is `<project>/<session>.jsonl` and a subagent's is
      # `<project>/<session>/subagents/agent-<id>.jsonl` with a `.meta.json` beside it naming its
      # `agentType`, which is the role; a top-level session has no meta and reads as `session`. A
      # call written as several lines under one `message.id` counts once; a line with no usage adds
      # zero; a line that is not JSON is skipped and counted. Each file is read from its tail up to
      # `TAIL_BYTES`, and a file the limit cut short is counted as capped.
      class Transcripts
        # The most bytes read from the end of one transcript.
        TAIL_BYTES = 8 * 1024 * 1024
        # The end of a transcript's name, which its meta file's name replaces.
        TRANSCRIPT_SUFFIX = /\.jsonl\z/

        # @return [Integer] lines that were not JSON
        attr_reader :skipped
        # @return [Integer] files the byte limit cut short
        attr_reader :capped

        # @param root [String] the projects directory the transcripts are under
        # @param window [Range<Time>] the moments a call is counted in
        def initialize(root, window)
          @root = root
          @window = window
          @skipped = 0
          @capped = 0
        end

        # @return [Array<Hash>] `{ role:, usage: }` for each distinct call in the window
        def calls
          @calls ||= files.flat_map { |path| from(path) }.uniq { |call| call[:id] || call.object_id }
        end

        private

        def files
          Dir.glob([File.join(@root, "*", "*.jsonl"), File.join(@root, "*", "*", "subagents", "*.jsonl")])
             .select { |path| File.mtime(path) >= @window.begin }
        end

        def from(path)
          role = role_of(path)
          lines(path).filter_map { |line| call(line, role) }
        end

        def role_of(path)
          meta = path.sub(TRANSCRIPT_SUFFIX, ".meta.json")
          File.exist?(meta) ? JSON.parse(File.read(meta))["agentType"].to_s : "session"
        rescue JSON::ParserError
          "session"
        end

        def lines(path)
          size = File.size(path)
          cut = size > TAIL_BYTES
          @capped += 1 if cut
          text = tail(path, size, cut)
          cut ? text.lines.drop(1) : text.lines
        end

        def tail(path, size, cut)
          File.open(path) do |file|
            file.seek(size - TAIL_BYTES) if cut
            file.read
          end
        end

        def call(line, role)
          entry = JSON.parse(line)
          message = entry["message"] || {}
          return unless entry["type"] == "assistant" && inside?(entry["timestamp"])

          { id: message["id"], role: role, usage: usage(message["usage"]) }
        rescue JSON::ParserError
          @skipped += 1
          nil
        end

        def inside?(stamp) = !stamp.nil? && @window.cover?(Time.iso8601(stamp))

        def usage(held)
          held = {} unless held.is_a?(Hash)
          Calc::COUNTS.to_h { |count| [count, held[count.to_s].to_i] }
        end
      end
    end
  end
end
