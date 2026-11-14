# frozen_string_literal: true

module Hecks
  module Adapters
    class Standup
      # The text of a standup: four headed sections a blank line apart, each line indented under
      # its heading, and a line that says so when a section holds nothing.
      class Text
        # What the blocked section says while the stall ledger cannot list its open stalls.
        UNLISTED = "not listed in this standup yet"

        # @param since [Integer] the time the finished section covers from, in epoch seconds
        # @param finished [Array<String>, nil] the finished work items; nil when no tap is declared
        # @param upcoming [Array<String>] the next planned work items
        # @param machine [String] the machine's gauges in one line
        def initialize(since, finished:, upcoming:, machine:)
          @since = since
          @finished = finished
          @upcoming = upcoming
          @machine = machine
        end

        # @return [String] the standup, ending in a newline
        def to_s = "#{sections.map { |heading, lines| part(heading, lines) }.join("\n\n")}\n"

        private

        def sections
          [["Finished since #{Time.at(@since).utc.iso8601}:", finished], ["Blocked or old:", [UNLISTED]],
           ["Starts next:", either(@upcoming, "nothing is planned")],
           ["Load and memory:", either([@machine].reject(&:empty?), "the machine gave no reading")]]
        end

        def finished = @finished ? either(@finished, "nothing") : ["not read: no event tap is declared"]

        def either(lines, otherwise) = lines.empty? ? [otherwise] : lines

        def part(heading, lines) = ([heading] + lines.map { |line| "  #{line}" }).join("\n")
      end
    end
  end
end
