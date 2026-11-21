# frozen_string_literal: true

require "time"
require_relative "openings"
require_relative "computed_row"

module Hecks
  module Adapters
    class StallWatching
      # The `run-finished` read: an opening line no closing line followed whose run, the same id on
      # the row's `ends_aggregate`, ended since: the one waiting for the answer waits for ever. It
      # counts from the run's end and is an impediment once it has lasted the row's minutes.
      class FinishedRuns
        # @param now [Integer] the clock's answer, in Unix epoch seconds
        def initialize(now)
          @now = now
        end

        # @param signal [Hash] a `ComputedSignal` row of this read
        # @param lines [Array<Hash>] tap lines in sequence order
        # @param run [String] the look that asks
        # @return [Array<Hash>] one `Sighting` row per open line whose run ended long enough ago
        def rows(signal, lines, run)
          openings = Openings.new(signal, lines)
          openings.unclosed.filter_map do |subject, opened|
            ended = ended_at(signal, lines, subject, opened)
            next unless ended && (@now - ended.to_i) / 60 >= signal[:minutes].to_i

            row(signal, run, subject, ended, openings.links(subject))
          end
        end

        private

        def ended_at(signal, lines, subject, opened)
          events = signal[:ends].to_s.split(",")
          line = lines.find do |one|
            one["aggregate"] == signal[:ends_aggregate] && one["id"] == subject && events.include?(one["event"]) &&
              one["at"] >= opened
          end
          Time.iso8601(line["at"]) if line
        end

        def row(signal, run, subject, ended, links)
          work = links["work"] ? " Its work item: #{links["work"]}." : ""
          detail = "#{signal[:aggregate]} #{subject} recorded #{signal[:opens]} and its run ended at " \
                   "#{ended.utc.iso8601} with no #{signal[:closes].to_s.split(",").first}.#{work}"
          ComputedRow.of(signal, run, { subject: subject, at: ended, detail: detail }, now: @now)
        end
      end
    end
  end
end
