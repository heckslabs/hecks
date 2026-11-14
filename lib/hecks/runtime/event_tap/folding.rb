# frozen_string_literal: true

require "json"
require "time"

module Hecks
  module Runtime
    class EventTap
      # The fold of a generation's repeated lines, applied when it is archived. A line that says
      # what an earlier one said (the same in everything but its time and sequence number) within
      # `GAP` seconds of it is counted on that earlier line as `repeats`, with the time of the
      # newest repeat as `last_at`. A silence longer than `GAP` starts a new line, so a stop
      # still shows in the archive. A line that is not a JSON object is kept as it is.
      class Folding
        # The keys in which a repeat may differ from the line it repeats.
        VARYING = %w[at seq].freeze

        # Seconds between two lines past which the later one is no repeat of the earlier.
        GAP = 300

        # @param texts [Enumerable<String>] a generation's lines, oldest first
        # @return [Array<String>] the lines with each run of repeats folded into its first line
        def fold(texts)
          @open = {}
          kept = texts.filter_map { |text| take(text) }
          kept.map { |line| line.is_a?(String) ? line : JSON.generate(line) }
        end

        private

        # The line to keep for a text: itself when it opens a run, nothing when it repeats one.
        def take(text)
          line = JSON.parse(text)
          return text unless line.is_a?(Hash)

          key = line.except(*VARYING)
          first = @open[key]
          first && near?(first, line) ? count(first, line) : @open[key] = line
        rescue JSON::ParserError
          text
        end

        # Counts a repeat on the line that opened its run. It answers nil: a repeat keeps no line.
        def count(first, line)
          first["repeats"] = first.fetch("repeats", 0) + 1
          first["last_at"] = line["at"]
          nil
        end

        def near?(first, line)
          (seconds(line["at"]) - seconds(first.fetch("last_at") { first["at"] })).abs <= GAP
        rescue ArgumentError, TypeError
          false
        end

        def seconds(stamp) = Time.iso8601(stamp).to_i
      end
    end
  end
end
