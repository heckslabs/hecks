# frozen_string_literal: true

require "json"

module Hecks
  module Adapters
    module PipelineBoard
      # What a blocked session said last and what it did just before, read from the end of its
      # transcript: the question it is waiting on, and its last few tool calls. Reads only, and only
      # the tail, so a long session costs the same as a short one.
      module SessionContext
        TAIL_BYTES = 512 * 1024
        SAID_CHARS = 1200
        STEPS = 3
        STEP_CHARS = 160

        module_function

        # @param path [String] the session's transcript (JSON lines)
        # @return [Hash{Symbol => Object}] `said:` the last text the session wrote, `did:` its last
        #   tool calls, oldest first; both empty when the transcript cannot be read
        def of(path)
          assistant = entries(path).select { |entry| entry["type"] == "assistant" }
          { said: said(assistant), did: did(assistant) }
        rescue SystemCallError, IOError
          { said: "", did: [] }
        end

        def said(assistant)
          text = assistant.reverse_each.map { |entry| texts(entry) }.find { |found| !found.empty? }
          text.to_s[0, SAID_CHARS]
        end

        # The last few steps across the assistant's turns, oldest first.
        def did(assistant)
          newest_first = assistant.reverse_each.flat_map { |entry| steps(entry) }
          newest_first.first(STEPS).reverse
        end

        def texts(entry)
          content(entry).select { |part| part["type"] == "text" }.map { |part| part["text"].to_s }.join("\n")
        end

        def steps(entry)
          content(entry).select { |part| part["type"] == "tool_use" }.map do |part|
            "#{part["name"]} #{JSON.generate(part["input"]).slice(0, STEP_CHARS)}"
          end.reverse
        end

        def content(entry)
          Array(entry.dig("message", "content")).grep(Hash)
        end

        # The parsed lines of the transcript's last TAIL_BYTES, the first line dropped when cut.
        def entries(path)
          size = File.size(path)
          text = File.open(path) { |file| file.seek([size - TAIL_BYTES, 0].max) && file.read }
          lines = text.lines
          lines = lines.drop(1) if size > TAIL_BYTES
          lines.filter_map { |line| parse(line) }
        end

        def parse(line)
          JSON.parse(line)
        rescue JSON::ParserError
          nil
        end
      end
    end
  end
end
