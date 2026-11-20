# frozen_string_literal: true

require "time"
require_relative "cache"
require_relative "registry_store"
require_relative "pipeline_fill/report"
require_relative "../../hecks/adapters/started_work"

module Hecks
  module Adapters
    # Reads the last filling of the queue: which planned Work items it would start, which it skips
    # and why, plus the load and cap it saw. A rolling fill records its report on its `Roll`, so
    # the tile reads that record in this process (through the live store when the board is pointed
    # at one, else the booted registry) and starts no process. The report's header ends with the
    # time the fill ran (`at <ISO 8601>`), which the preview carries as `at`. The last filling is
    # the report whose stated time is the latest: a store answers its records in the order of
    # their keys, which says nothing of when each ran. The preview also carries the report's age
    # in minutes; whether that age is stale is the bluebook's `Fill age` rows' to say. Where the
    # store holds no report the tile says so: the board never asks a launcher for a preview, since
    # a launcher boot on a timer is load the board would add to the machine it reports on.
    class PipelineFill
      # What the tile says while no fill has recorded a report.
      NONE_RECORDED = "no fill has recorded a report yet"

      # @param aggregate [Object, nil] unused
      # @param settings [Hash] `report:` stands in for the last recorded report (a callable
      #   answering its text or nil); `now:` stands in for the clock (a callable answering a Time)
      # @param root [String, nil] unused
      # @param registry [Runtime::Registry, nil] the booted registry the `Roll` records are read
      #   from when no `store:` is named
      # @param store [#records, nil] where the `Roll` records are read: the live store when the
      #   board is pointed at one, so a report recorded by another process is found
      def initialize(aggregate: nil, settings: {}, root: nil, registry: nil, store: nil)
        @store = store || PipelineBoard::RegistryStore.new(registry: registry)
        @recorded = settings[:report] || method(:recorded_report)
        @now = settings[:now] || -> { Time.now }
      end

      # @return [Hash] `load`, `limit`, `cap`, `started`, `headroom`, `per_session` (nil when
      #   unstated), `at` and `age_minutes` (nil when the report states no time), `would_start`
      #   (slug and title), `launched` (slug) and `skipped` (slug and reason, a yielded item
      #   included)
      # @raise [PipelineBoard::Unavailable] when no report is recorded, or it cannot be read
      def preview
        text = @recorded.call.to_s
        raise PipelineBoard::Unavailable, NONE_RECORDED if text.empty?

        reading = Report.parse(text) or raise PipelineBoard::Unavailable, "unreadable fill report"
        reading.merge(age_minutes: age_minutes(reading[:at]))
      end

      private

      # The report with the latest stated time, or nil when the store holds none. Of two that
      # state one time the later in the store's order is taken; a report that states no time
      # ranks below every one that does, the later in the store's order first.
      def recorded_report
        readable = reports.select { |report| Report.readable?(report) }
        readable.each_with_index.max_by { |report, place| [Report.ran_at(report).to_s, place] }&.first
      end

      # @return [Array<String>] the report of each `Roll` record, in the store's order; none when
      #   the store cannot be read or declares no `Roll`
      def reports
        @store.records("Hecks", "Roll").map { |roll| StartedWork.value(roll, :report).to_s }
      rescue PipelineBoard::Unavailable
        []
      end

      # @return [Integer, nil] the whole minutes since the stated time, nil when none is stated
      def age_minutes(stated)
        stated && ((@now.call - Time.iso8601(stated)) / 60).floor
      end
    end
  end
end
