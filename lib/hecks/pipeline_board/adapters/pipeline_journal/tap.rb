# frozen_string_literal: true

require "json"

module Hecks
  module Adapters
    module PipelineBoard
      # Reads the runtime's opt-in event log (`Hecks::Runtime::EventTap`): one JSON line per event
      # and one per policy delivery, which this reader attaches to the event it answered. A line
      # that carries its own `policy` is an event with its reaction. It opens the file for reading
      # only; a missing file holds no events.
      class Tap
        TAIL_LINES = 600
        FOLLOWING = 3

        # @param path [String] the log's path
        def initialize(path)
          @path = path
        end

        # @return [Array<Hash>] the newest events as board rows, oldest first, each with the
        #   reactions the log holds for it
        def rows
          return [] unless File.file?(@path)

          events = parse(File.readlines(@path).last(TAIL_LINES))
          link(events)
        rescue SystemCallError
          []
        end

        private

        def parse(lines) = lines.filter_map { |line| decode(line) }

        def decode(line)
          JSON.parse(line)
        rescue JSON::ParserError
          nil
        end

        def link(lines)
          rows = []
          lines.each { |line| line["kind"] == "reaction" ? attach(rows, line) : rows << event_row(line, rows.size) }
          rows.each_with_index { |row, index| follow(row, rows.drop(index + 1)) }
        end

        def event_row(data, index)
          { key: "tap:#{data["at"]}:#{data["aggregate"]}:#{data["id"]}:#{data["event"]}:#{index}", source: "tap",
            at: data["at"], aggregate: data["aggregate"], id: data["id"], name: data["event"], reactions: inline(data) }
        end

        def inline(data) = data["policy"] ? [reaction(data)] : []

        def reaction(data)
          { policy: data["policy"], command: data["command"].to_s, outcome: data["outcome"].to_s,
            emitted: Array(data["emitted"]) }
        end

        def attach(rows, line)
          row = rows.reverse.find { |held| held[:id].to_s == line["id"].to_s && held[:name] == bare(line["event"]) }
          row[:reactions] << reaction(line) if row
        end

        def bare(name) = name.to_s.split(".").last

        def follow(row, later)
          names = later.select { |other| other[:id] == row[:id] && other[:name] != row[:name] }.first(FOLLOWING)
          row[:reactions].each { |reaction| reaction[:emitted] = names.map { |other| other[:name] } if reaction[:emitted].empty? }
          row
        end
      end
    end
  end
end
