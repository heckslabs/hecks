# frozen_string_literal: true

require "hecks/runtime/event_feed"
require "hecks/adapters/driven/system_clock"
require "hecks/hecks/adapters/started_work"
require "hecks/hecks/adapters/console_capture"
require_relative "outcome_readings/reading"
require_relative "outcome_readings/subject"

module Hecks
  module Adapters
    # The `OutcomeReadings` port's adapter for `Tickets::Epic`: reads the number an epic's
    # `OutcomeMeasure` row counts on the event tap and answers it beside the row's bounds.
    #
    # It judges nothing: `Epic.Complete` and `Epic.Miss` compare the number with the bounds. It
    # reads the tap as the stall watch does, through `Runtime::EventFeed`, and never writes.
    class OutcomeReadings
      # The most tap lines one reading takes: every rotated generation the tap keeps.
      EVERY_LINE = 10**9

      # The upper bound answered for a row that states none.
      UNBOUNDED = 10**9

      # @param registry [Runtime::Registry, nil] the booted registry; its Hecks world names the tap
      # @param aggregate [Object, nil] unused: the rows are read from the registry's Epic
      # @param tap [String, nil] a log in place of the world's, for a spec; a boot never passes it
      def initialize(registry: nil, aggregate: nil, tap: nil)
        @registry = registry
        @tap = tap
      end

      # Reads the number of the epic's measure.
      #
      # @param held [Hash] the Epic: `epic`
      # @return [Hash{Symbol => Hash}] `reading`, `at_least`, `at_most`, the `evidence` in words and
      #   `finding`, the work item a miss would be planned as
      # @raise [ConsoleCapture::Failure] when the epic names no measure or no row, or no tap
      #   is declared
      def read_outcome(**held)
        subject = Subject.new(@registry, plain(held[:epic]).to_s)
        row = subject.row(rows)
        reading = Reading.new(row, SystemClock.now)
        number = reading.number(lines(subject))
        bounds(row).merge(reading: { value: number }, evidence: { value: "#{reading.words(number)} #{subject.again}" },
                          finding: { value: subject.finding })
      end

      # @return [Array<Hash{Symbol => Object}>] the `OutcomeMeasure` rows, as the bluebook
      #   declares them
      def rows
        declared = Subject.epic_aggregate(@registry)&.value_objects&.find { |object| object.hecks_name == "OutcomeMeasure" }
        Array(declared&.members).map { |row| row.to_h.transform_keys(&:to_sym).compact }
      end

      private

      def plain(argument) = argument.is_a?(Hash) ? argument[:value] : argument

      def bounds(row) = { at_least: { value: row[:at_least].to_i }, at_most: { value: row[:at_most] || UNBOUNDED } }

      def lines(subject)
        path = tap_path
        raise ConsoleCapture::Failure, "no event tap is declared, so the outcome of #{subject.key} is not read" unless path

        Runtime::EventFeed.new(path: path).read(since: 0, limit: EVERY_LINE)[:events]
      end

      # Where the Hecks world keeps its tap, moved as a boot moves it (`HECKS_EVENT_TAP`).
      def tap_path
        return @tap if @tap

        settings = @registry&.world("Hecks")&.for_verb(Runtime::EventTap::VERB).to_h
        Runtime::EventTap.path_for(settings, Assembly.event_tap_override)
      end
    end
  end
end
