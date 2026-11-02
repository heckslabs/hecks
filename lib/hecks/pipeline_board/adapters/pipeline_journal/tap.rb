# frozen_string_literal: true

require "json"

module Hecks
  module Adapters
    module PipelineBoard
      # Reads the opt-in append-only event log (one JSON line per event, with the policy that
      # reacted when there was one). It opens the file for reading only; a missing file holds no
      # events.
      class Tap
        TAIL_LINES = 400

        # @param path [String] the log's path
        def initialize(path)
          @path = path
        end

        # @return [Array<Hash>] the newest lines as board rows, oldest first
        def rows
          return [] unless File.file?(@path)

          lines = File.readlines(@path).last(TAIL_LINES)
          lines.each_with_index.filter_map { |line, index| row(line, index) }
        rescue SystemCallError
          []
        end

        private

        def row(line, index)
          data = JSON.parse(line)
          { key: "tap:#{data["at"]}:#{index}", source: "tap", at: data["at"], aggregate: data["aggregate"],
            id: data["id"], name: data["event"], reactions: reactions(data) }
        rescue JSON::ParserError
          nil
        end

        def reactions(data)
          return [] unless data["policy"]

          [{ policy: data["policy"], command: data["command"].to_s, outcome: data["outcome"].to_s,
             emitted: Array(data["emitted"]) }]
        end
      end
    end
  end
end
