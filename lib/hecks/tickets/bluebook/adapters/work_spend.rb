# frozen_string_literal: true

require "time"
require "hecks/hecks/adapters/started_work"

module Hecks
  module Adapters
    # The `WorkSpend` port's adapter for `Tickets::Work`: the pomodoros the runs of a finished work
    # item spent. A run is the item's when it names the item as its `work`, or names nothing and its
    # run key is the item's key; a run that names another item is never borrowed. Each run counts
    # from its `started_at` to the `SessionFinished` event the registry logged for it, and the
    # seconds of every run add up before they are rounded up to whole 25-minute rounds, because a
    # bluebook rule has neither event times nor a ceiling. A run still going counts for nothing.
    #
    # It reads the registry and never writes. An item no run names spent none.
    class WorkSpend
      # Minutes in one pomodoro.
      ROUND = 25

      # @param registry [Runtime::Registry, nil] the booted registry whose AgentRun records and
      #   event log are read
      # @param aggregate [Object, nil] unused
      def initialize(registry: nil, aggregate: nil)
        @registry = registry
      end

      # @param held [Hash] the Work item `work`
      # @return [Hash{Symbol => Hash}] `pomodoros_spent:` whole rounds, 0 when no run is the item's
      def read_spend(**held)
        key = plain(held[:work]).to_s
        seconds = runs_of(key).sum { |record| seconds_of(record) }
        { pomodoros_spent: { value: (seconds / (ROUND * 60.0)).ceil } }
      end

      private

      def runs_of(key) = records.select { |record| theirs?(record, key) }

      def theirs?(record, key)
        named = read(record, :work)
        named.empty? ? read(record, :run) == key : named == key
      end

      def seconds_of(record)
        began = read(record, :started_at)
        ended = finished_at(record)
        return 0 if began.empty? || ended.nil?

        [Time.iso8601(ended.to_s) - Time.iso8601(began), 0].max
      end

      def finished_at(record)
        ids = [read(record, :run), read(record, :id)]
        event = @registry.event_log.reverse.find { |logged| logged.name == "SessionFinished" && ids.include?(logged.id.to_s) }
        event&.occurred_at
      end

      def records
        bluebook = @registry&.bluebook("Hecks")
        aggregate = bluebook&.aggregates&.find { |found| found.hecks_name == "AgentRun" }
        aggregate ? @registry.repository("Hecks", aggregate).all : []
      end

      def read(record, name) = StartedWork.value(record, name).to_s

      def plain(argument) = argument.is_a?(Hash) ? argument[:value] : argument
    end
  end
end
