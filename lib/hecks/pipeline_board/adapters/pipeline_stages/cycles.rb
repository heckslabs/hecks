# frozen_string_literal: true

require "time"
require_relative "../rules"

module Hecks
  module Adapters
    module PipelineBoard
      # A Work item's cycle laid against the `CycleStage` rows: each stage's start, end and seconds,
      # from the events the journal holds, and per stage the median and the `cycle_percentile` over
      # the recent items. The rows say which event opens and closes a stage and how an event
      # belongs to an item; this module only lines the events up and measures. It reads nothing.
      module Cycles
        module_function

        # @return [Array<String>] the bare event names the stage rows open and close on
        def event_names = stages.flat_map { |row| [row[:opens], row[:closes]] }.map { |name| name.split(".").last }.uniq

        # @param events [Array<Hash>] journal rows: `at`, `aggregate`, `id`, `name` and `links`
        # @param now [Time] the time an open stage is measured to
        # @param limit [Integer, nil] how many items (the `cycle_items` setting when nil)
        # @return [Hash] `cycles:` newest first, `stats:` one entry per stage, `rank:` the
        #   percentile the stats give
        def build(events, now, limit = nil)
          ordered = events.sort_by { |event| event[:at].to_s }
          found = keys(ordered).first(limit || Rules.setting("cycle_items")).map { |key| cycle(ordered, key, now) }
          { cycles: found, stats: stats(found), rank: Rules.setting("cycle_percentile") }
        end

        # @return [Array<Hash>] the `CycleStage` rows, in position order
        def stages = Rules.rows("CycleStage").sort_by { |row| row[:position] }

        # The items, newest first: the keys of the events that open the first stage.
        def keys(ordered)
          opening = ordered.select { |event| named?(event, stages.first[:opens]) }
          opening.reverse.map { |event| key_of(event) }.uniq
        end

        def cycle(ordered, key, now)
          start = ordered.reverse.find { |event| named?(event, stages.first[:opens]) && key_of(event) == key }
          measured = walk(ordered, key, start, now)
          { work: key, started: start[:at], stages: measured, open: measured.find { |entry| entry[:open] }&.dig(:stage),
            seconds: measured.sum { |entry| entry[:seconds] } }
        end

        # Each stage from the end of the one before, until a stage that has not closed.
        def walk(ordered, key, start, now)
          stages.each_with_object([]) do |row, measured|
            ending = closing(ordered, row, key, start)
            measured << measure(row, start, ending, now)
            break measured unless ending

            start = ending
          end
        end

        def closing(ordered, row, key, start)
          ordered.find do |event|
            event[:at].to_s >= start[:at].to_s && named?(event, row[:closes]) &&
              [key_of(event), event[:id].to_s].intersect?([key, start[:id].to_s])
          end
        end

        def measure(row, start, ending, now)
          finish = ending ? Time.parse(ending[:at]) : now
          { stage: row[:stage], start: start[:at], end: ending&.dig(:at), open: ending ? nil : true,
            seconds: (finish - Time.parse(start[:at])).round }
        end

        def stats(found)
          percentile = Rules.setting("cycle_percentile")
          stages.map do |row|
            sorted = closed(found, row[:stage])
            { stage: row[:stage], items: sorted.size, median: median(sorted), percentile: rank(sorted, percentile) }
          end
        end

        # The seconds of every closed span of one stage, shortest first.
        def closed(found, stage)
          spans = found.flat_map { |cycle| cycle[:stages] }.select { |entry| entry[:stage] == stage && !entry[:open] }
          spans.map { |entry| entry[:seconds] }.sort
        end

        def median(sorted)
          return nil if sorted.empty?

          middle = sorted.size / 2
          sorted.size.odd? ? sorted[middle] : ((sorted[middle - 1] + sorted[middle]) / 2.0).round
        end

        # The nearest-rank percentile.
        def rank(sorted, percentile) = sorted.empty? ? nil : sorted[((percentile / 100.0) * sorted.size).ceil - 1]

        # The Work item an event names: its `work` link, its `branch` link, or its own id. A link
        # the log holds as a printed object (`#<...>`) names nothing and is passed over.
        def key_of(event)
          links = event[:links] || {}
          [links["work"], links["branch"], event[:id]].map(&:to_s).find { |held| !held.empty? && !held.start_with?("#<") }
        end

        def named?(event, qualified) = "#{event[:aggregate]}.#{event[:name]}" == qualified
      end
    end
  end
end
