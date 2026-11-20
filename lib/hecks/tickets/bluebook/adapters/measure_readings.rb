# frozen_string_literal: true

require "json"
require "hecks/tickets/bluebook/adapters/outcome_readings"

module Hecks
  module Adapters
    # The `MeasureReadings` port's adapter for `Tickets::Epic`: every `OutcomeMeasure` row read from
    # the event tap now, whether or not an epic names it. Each entry holds the number, the row's
    # bounds, whether the number lies within them and how many of the row's minutes the tap could
    # see back. It reads and never writes; with no tap every row is answered `unread`.
    class MeasureReadings
      # The fields of a row an entry repeats as the bluebook declares them.
      DECLARED = %i[measure aggregate events minutes per span at_most].freeze

      # @param registry [Runtime::Registry, nil] the booted registry whose rows and tap are read
      # @param aggregate [Object, nil] unused
      # @param tap [String, nil] a log in place of the world's, for a spec; a boot never passes it
      def initialize(registry: nil, aggregate: nil, tap: nil)
        @rows = OutcomeReadings.new(registry: registry).rows
        @tap = OutcomeReadings::Tap.new(registry, tap)
      end

      # @return [Hash{Symbol => String}] `text:` a JSON array, one entry per row in declared order
      def measures(**)
        lines = @tap.lines
        now = SystemClock.now
        { text: "#{JSON.pretty_generate(@rows.map { |row| entry(row, lines, now) })}\n" }
      end

      private

      def entry(row, lines, now)
        declared = DECLARED.to_h { |field| [field, row[field]] }.merge(at_least: row[:at_least].to_i)
        declared.merge(lines ? read(OutcomeReadings::Reading.new(row, now), lines) : unread)
      end

      def read(reading, lines)
        number = reading.number(lines)
        { reading: number, state: reading.met?(number) ? "met" : "missed", saw_back_minutes: reading.sight(lines) }
      end

      def unread = { reading: nil, state: "unread", saw_back_minutes: 0, note: "no event tap is declared" }
    end
  end
end
