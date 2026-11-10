# frozen_string_literal: true

require "time"
require_relative "../rules"
require_relative "cycles/belonging"

module Hecks
  module Adapters
    module PipelineBoard
      # A Work item's cycle laid against the `CycleStage` rows: each stage's start, end and seconds,
      # from the events the journal holds, and per stage the median and the `cycle_percentile` over
      # the recent items. The rows say which events open and close a stage and how an event
      # belongs to an item; this module only lines the events up and measures. It reads nothing.
      module Cycles
        module_function

        # @return [Array<String>] the bare event names the stage rows open and close on
        def event_names = stages.flat_map { |row| [row[:opens], *names_of(row)] }.map { |name| name.split(".").last }.uniq

        # @param events [Array<Hash>] journal rows: `at`, `aggregate`, `id`, `name` and `links`
        # @param now [Time] the time an open stage is measured to
        # @param limit [Integer, nil] how many items (the `cycle_items` setting when nil)
        # @return [Hash] `cycles:` newest first, `stats:` one entry per stage, `rank:` the
        #   percentile the stats give
        def build(events, now, limit = nil)
          ordered = events.sort_by { |event| event[:at].to_s }
          landings = Belonging.landings(ordered)
          found = keys(ordered).first(limit || Rules.setting("cycle_items")).map { |key| cycle(ordered, key, now, landings) }
          { cycles: found, stats: stats(found), rank: Rules.setting("cycle_percentile") }
        end

        # @return [Array<Hash>] the `CycleStage` rows, in position order
        def stages = Rules.rows("CycleStage").sort_by { |row| row[:position] }

        # The items, newest first: the keys of the events that open the first stage.
        def keys(ordered)
          opening = ordered.select { |event| named?(event, stages.first[:opens]) }
          opening.reverse.map { |event| Belonging.key_of(event) }.uniq
        end

        def cycle(ordered, key, now, landings)
          start = ordered.reverse.find { |event| named?(event, stages.first[:opens]) && Belonging.key_of(event) == key }
          held = { key: key, start: start, landings: landings, landed_at: Belonging.landed_at(ordered, key) }
          summary(key, start, walk(ordered, held, now))
        end

        # An item is done when its last stage has closed.
        def summary(key, start, measured)
          open = measured.find { |entry| entry[:open] }&.dig(:stage)
          { work: key, started: start[:at], stages: measured, open: open, done: open.nil? && measured.size == stages.size,
            seconds: measured.sum { |entry| entry[:seconds] } }
        end

        # Each stage from the end of the one before, until a stage that has not closed.
        def walk(ordered, held, now)
          stages.each_with_object([]) do |row, measured|
            ending = closing(ordered, row, held)
            measured << measure(row, held[:start], ending, now)
            break measured unless ending

            held = held.merge(start: ending)
          end
        end

        def closing(ordered, row, held)
          ordered.find do |event|
            event[:at].to_s >= held[:start][:at].to_s && names_of(row).any? { |name| named?(event, name) } &&
              Belonging.belongs?(row[:belongs].to_s, event, held)
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

        # A row's closing events: one, or several separated by a space.
        def names_of(row) = row[:closes].to_s.split

        def named?(event, qualified) = "#{event[:aggregate]}.#{event[:name]}" == qualified
      end
    end
  end
end
