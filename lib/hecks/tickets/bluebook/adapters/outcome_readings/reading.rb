# frozen_string_literal: true

require "time"

module Hecks
  module Adapters
    class OutcomeReadings
      # The number one `OutcomeMeasure` row reads from tap lines: how many of the row's events its
      # aggregate recorded inside the row's window, or, for a row read `per: "id"`, the most one
      # aggregate id recorded inside any `span` minutes of it. It counts and compares nothing.
      class Reading
        # @param row [Hash] an `OutcomeMeasure` row
        # @param now [Integer] the time the window ends at, in epoch seconds
        def initialize(row, now)
          @row = row
          @now = now
        end

        # @param lines [Array<Hash>] tap lines
        # @return [Integer] the row's number over those lines
        def number(lines)
          by_id = times(lines)
          return by_id.values.sum(&:size) unless per_id?

          by_id.values.map { |times| densest(times) }.max || 0
        end

        # @param number [Integer] what was read
        # @return [String] the reading in words, with the row's bounds
        def words(number)
          "#{@row[:measure]} read #{number}: #{counted} in the last #{@row[:minutes]} minutes; wanted #{bounds}."
        end

        private

        def per_id? = @row[:per] == "id"

        def counted
          events = "#{@row[:events]} of #{@row[:aggregate]}"
          per_id? ? "the most #{events} by one id within #{@row[:span]} minute(s)" : events
        end

        def bounds
          least = "at least #{@row[:at_least].to_i}"
          @row[:at_most] ? "#{least} and at most #{@row[:at_most]}" : least
        end

        # Each aggregate id with the epoch seconds of its counted lines inside the window.
        def times(lines)
          since = @now - (@row[:minutes].to_i * 60)
          stamped = mine(lines).map { |line| [line["id"].to_s, at(line)] }
          stamped.select { |_, at| at >= since }.group_by(&:first).transform_values { |pairs| pairs.map(&:last) }
        end

        def at(line) = Time.parse(line["at"].to_s).to_i

        def mine(lines)
          events = @row[:events].to_s.split(",").map(&:strip)
          lines.select do |line|
            line["kind"] == "event" && line["aggregate"] == @row[:aggregate] && events.include?(line["event"])
          end
        end

        # The most lines that begin inside one span of the row.
        def densest(times)
          span = @row[:span].to_i * 60
          times.map { |start| times.count { |at| at >= start && at - start < span } }.max
        end
      end
    end
  end
end
