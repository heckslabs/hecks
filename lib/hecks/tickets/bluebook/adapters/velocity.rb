# frozen_string_literal: true

require "time"
require "hecks/runtime/event_feed"
require "hecks/hecks/adapters/started_work"
require_relative "velocity/git_span"
require_relative "velocity/text"

module Hecks
  module Adapters
    # The `Velocity` port's adapter for `Tickets::Work`: the hours of work finished on a day.
    #
    # A finished item that recorded the pomodoros it spent counts them at 25 minutes each. One that
    # recorded none is read from git, the span from its branch's first commit to its merge on
    # `main`, and every such figure is marked inferred. It reads and never writes.
    class Velocity
      # The most tap lines one read takes: every rotated generation the tap keeps.
      EVERY_LINE = 10**9

      # @param registry [Runtime::Registry, nil] the booted registry whose Work items are read
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] stand-ins: `tap:` a log path, `span:` answers seconds for a key
      # @param root [String, nil] the checkout whose git history is read
      def initialize(registry: nil, aggregate: nil, settings: {}, root: nil)
        @registry = registry
        @standins = settings
        @root = settings[:root] || root
      end

      # @param held [Hash] the query's `day`, an ISO date; today when absent
      # @return [Hash{Symbol => String}] `text:` the report
      def velocity(**held)
        day = plain(held[:day]) || Time.now.utc.strftime("%Y-%m-%d")
        { text: Text.new(day, finished_on(day).map { |key| item(key) }).to_s }
      end

      private

      def item(key)
        record = records[key]
        spent = record ? StartedWork.value(record, :pomodoros_spent).to_i : 0
        { key: key, title: record && StartedWork.value(record, :title), spent: spent,
span: spent.positive? ? nil : span.call(key) }
      end

      def span = @standins[:span] || GitSpan.new(@root)

      def records
        @records ||= (aggregate = StartedWork.work_aggregate(@registry)) ? keyed(aggregate) : {}
      end

      def keyed(aggregate) = @registry.repository("Tickets", aggregate).all.to_h { |r| [StartedWork.value(r, :work).to_s, r] }

      def finished_on(day)
        lines = Runtime::EventFeed.new(path: @standins[:tap]).read(since: 0, limit: EVERY_LINE)[:events]
        lines.select { |line| finished?(line) && line["at"].to_s.start_with?(day) }.map { |line| line["id"].to_s }.uniq
      end

      def finished?(line) = line["aggregate"] == "Tickets::Work" && line["event"] == "WorkFinished"

      def plain(argument) = argument.is_a?(Hash) ? argument[:value] : argument
    end
  end
end
