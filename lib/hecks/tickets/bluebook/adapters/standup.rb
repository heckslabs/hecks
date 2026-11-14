# frozen_string_literal: true

require "hecks/runtime/event_feed"
require "hecks/adapters/driven/system_clock"
require "hecks/hecks/adapters/started_work"
require "hecks/hecks/adapters/machine_sampling/readings"
require_relative "priority_report"
require_relative "standup/window"
require_relative "standup/finished"
require_relative "standup/upcoming"
require_relative "standup/gauges"
require_relative "standup/text"

module Hecks
  module Adapters
    # The `Standup` port's adapter for `Tickets::Work`: says what finished since a time, what
    # starts next and how loaded the machine is.
    #
    # It decides nothing. The finished work items are the tap's `WorkFinished` lines, the next
    # ones are {PriorityReport#rows} in the order they come, the window is the bluebook's
    # `StandupWindow` row and the gauges are the machine's own. It reads and never writes.
    class Standup
      # The most tap lines one standup reads: every rotated generation the tap keeps.
      EVERY_LINE = 10**9

      # @param registry [Runtime::Registry, nil] the booted registry whose Work items are read
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] stand-ins: `tap:` a log in place of the world's, `now:` answers
      #   epoch seconds, `readings:` answers the gauges, and those {PriorityReport} takes
      # @param root [String, nil] unused
      def initialize(registry: nil, aggregate: nil, settings: {}, root: nil)
        @registry = registry
        @standins = settings
      end

      # Says the standup.
      #
      # @param held [Hash] the query's `since`, an ISO 8601 time; the window's hours when absent
      # @return [Hash{Symbol => String}] `text:` the headed sections, ending in a newline
      # @raise [ConsoleCapture::Failure] when `since` is not a time
      def standup(**held)
        since = window.since(plain(held[:since]))
        { text: Text.new(since, finished: finished(since), upcoming: upcoming, machine: gauges).to_s }
      end

      private

      def window = @window ||= Window.new(work_aggregate, now)

      def now = (@standins[:now] || SystemClock.method(:now)).call

      def finished(since)
        path = tap_path
        path && Finished.new(lines(path), titles).since(since)
      end

      def upcoming = Upcoming.new(report.rows, titles).first(window.upcoming)

      def gauges = Gauges.new(readings.call, report.max_load).line

      def readings = @standins[:readings] || -> { MachineSampling::Readings.new.call }

      def report = @report ||= PriorityReport.new(registry: @registry, settings: @standins)

      def work_aggregate = StartedWork.work_aggregate(@registry)

      # Each work item's title by its key.
      def titles
        @titles ||= work_aggregate.then do |aggregate|
          records = aggregate ? @registry.repository("Tickets", aggregate).all : []
          records.to_h { |record| [StartedWork.value(record, :work).to_s, StartedWork.value(record, :title).to_s] }
        end
      end

      def lines(path) = Runtime::EventFeed.new(path: path).read(since: 0, limit: EVERY_LINE)[:events]

      # Where the Hecks world keeps its tap, moved as a boot moves it (`HECKS_EVENT_TAP`).
      def tap_path
        return @standins[:tap] if @standins[:tap]

        settings = @registry&.world("Hecks")&.for_verb(Runtime::EventTap::VERB).to_h
        Runtime::EventTap.path_for(settings, Assembly.event_tap_override)
      end

      def plain(argument) = argument.is_a?(Hash) ? argument[:value] : argument
    end
  end
end
