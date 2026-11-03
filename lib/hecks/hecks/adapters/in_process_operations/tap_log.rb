# frozen_string_literal: true

require "json"
require "hecks/runtime/event"

module Hecks
  module Adapters
    module InProcessOperations
      # The event tap read as an event log, for a tail: every `event` line of the file, in order,
      # as a `Runtime::Event` (a payload only where the tap wrote one). It reads what the file
      # grew by since the last look and starts over when the file was rotated or removed, so a
      # cursor counts entries, as it does over a persisted journal. It never writes.
      class TapLog
        # @param path [String] the tap's file
        def initialize(path)
          @path = path
          @events = []
          @read = 0
        end

        # @return [Array<Runtime::Event>] every event the tap holds, oldest first
        def events
          size = File.exist?(@path) ? File.size(@path) : 0
          restart if size < @read
          grow if size > @read
          @events
        end

        private

        def restart
          @events = []
          @read = 0
        end

        # Takes each whole line; one still being written (no newline yet) waits for the next look.
        def grow
          File.open(@path, "r") do |file|
            file.seek(@read)
            file.each_line do |line|
              break unless line.end_with?("\n")

              take(line)
              @read = file.pos
            end
          end
        rescue SystemCallError
          nil
        end

        def take(line)
          data = JSON.parse(line)
          return unless data["kind"] == "event"

          @events << Runtime::Event.new(name: data["event"], aggregate: data["aggregate"], id: data["id"],
                                        payload: data.fetch("payload", {}), occurred_at: data["at"])
        rescue JSON::ParserError
          nil
        end
      end
    end
  end
end
