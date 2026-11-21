# frozen_string_literal: true

require_relative "../rules"
require_relative "readings"

module Hecks
  module Adapters
    module PipelineBoard
      # How much landed work came back, laid against the `ReworkCheck` rows: the rows say which
      # events and which titles count, the `Verdict` rows say the state. This only counts and forms
      # the share; with nothing landed, or a log that could not be read, the rate has no reading.
      module Rework
        module_function

        # @return [Array<String>] the bare names of the events the rows open on
        def event_names = event_rows.map { |row| row[:opens].split(".").last }

        # @param work [Array<Hash>] the landed Work items (`slug`, `title`, `epic`)
        # @param events [Array<Hash>, nil] board rows from the journal, nil when unreadable
        # @param at [String] when they were read
        # @return [Array<Hash>] one `Reading` per `ReworkCheck` row, then the rework rate
        def build(work, events, at)
          found = Rules.rows("ReworkCheck").to_h { |row| [row[:kind], items(row, work, events)] }
          counts = Rules.rows("ReworkCheck").map { |row| count(row, found[row[:kind]], at) }
          counts << rate(work, found.values, at)
        end

        def event_rows = Rules.rows("ReworkCheck").select { |row| row[:test] == "event" }

        # @return [Array<String>, nil] the items the row finds, nil when its events are unread
        def items(row, work, events)
          return titled(row, work) if row[:test] == "title"

          events&.select { |event| event_of?(row, event) }&.map { |event| link(row, event) }&.uniq
        end

        def event_of?(row, event) = row[:opens] == "#{event[:aggregate]}.#{event[:name]}"

        def link(row, event)
          row[:link].empty? ? event[:id].to_s : event[:links].to_h.transform_keys(&:to_s)[row[:link]].to_s
        end

        # The items titled with the row's prefix whose epic another landed item shares.
        def titled(row, work)
          work.select { |item| item[:title].to_s.downcase.start_with?(row[:prefix]) && sibling?(item, work) }
              .map { |item| item[:slug].to_s }
        end

        def sibling?(item, work)
          !item[:epic].to_s.empty? && work.any? { |other| other[:slug] != item[:slug] && other[:epic] == item[:epic] }
        end

        def count(row, found, at)
          size = found&.size
          { key: row[:kind], label: row[:says], value: size.to_s, unit: "",
            state: Rules.verdict("Rework count", { found: size }), note: found ? found.join(" ") : "no reading: unread" }
            .merge(Readings.read("rework", at))
        end

        # The share of the landed items that came back, in percent.
        def rate(work, found, at)
          share = share_of(work, found)
          { key: "rework_rate", label: "rework rate", value: share ? share.to_s : "", unit: "%",
            state: Rules.verdict("Rework", { share: share }), note: share ? "of #{work.size} landed" : "no reading" }
            .merge(Readings.read("rework", at))
        end

        def share_of(work, found)
          return nil if work.empty? || found.any?(&:nil?)

          (found.flatten.uniq.size * 100.0 / work.size).round
        end
      end
    end
  end
end
