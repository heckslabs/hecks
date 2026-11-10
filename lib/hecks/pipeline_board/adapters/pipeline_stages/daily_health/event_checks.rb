# frozen_string_literal: true

require "time"
require_relative "../../rules"

module Hecks
  module Adapters
    module PipelineBoard
      module DailyHealth
        # The checks of the daily health line that the events alone answer: `unanswered`, `over`
        # and `stuck` on a `HealthCheck` row. The row names the events and the join; this module
        # lines the events up and measures. It reads nothing.
        module EventChecks
          # A commit a link names: seven or more hex characters.
          SHA = /\A\h{7,}\z/

          module_function

          # @param row [Hash] a `HealthCheck` row
          # @param events [Array<Hash>] board rows, oldest first
          # @param now [Time] the time an open check is measured to
          # @param since [Time] the start of the day the openers are read from
          # @return [Array<Hash>] what the check found, each with `key`, `at` and its measure
          def found(row, events, now, since)
            openers = openers(row, events, since).select { |opener| readable?(row, opener) }
            case row[:test]
            when "unanswered" then unanswered(row, events, openers)
            when "over" then over(row, events, openers, now)
            else stuck(row, events, openers)
            end
          end

          # @return [Array<Hash>] the openers of the day whose key a link join cannot read
          def unreadable(row, events, since)
            openers(row, events, since).reject { |opener| readable?(row, opener) }.map { |opener| entry(opener, opener[:id]) }
          end

          # @return [Array<Hash>] the row's opening events, at or after `since`
          def openers(row, events, since)
            names = row[:opens].split
            events.select { |event| names.include?(qualified(event)) && Time.parse(event[:at]) >= since }
          end

          def unanswered(row, events, openers)
            openers.reject { |opener| closers(row, events, opener).any? { |closer| closer[:at] <= opener[:at] } }
                   .map { |opener| entry(opener, key(row, opener, 0)) }
          end

          def over(row, events, openers, now)
            bound = Rules.setting(row[:bound])
            openers.filter_map do |opener|
              closer = closers(row, events, opener).find { |event| event[:at] >= opener[:at] }
              minutes = minutes_between(opener, closer ? Time.parse(closer[:at]) : now)
              entry(opener, key(row, opener, 0)).merge(minutes: minutes, open: closer.nil?) if minutes > bound
            end
          end

          def minutes_between(opener, ending) = ((ending - Time.parse(opener[:at])) / 60).round

          def stuck(row, events, openers)
            openers.filter_map do |opener|
              turn = closers(row, events, opener).reverse.find { |closer| closer[:at] <= opener[:at] }
              parts = Array((turn&.dig(:payload) || {})["stuck"])
              entry(opener, key(row, opener, 0)).merge(stuck: parts.size) if parts.any?
            end
          end

          # The row's closing events of the opener's key.
          def closers(row, events, opener)
            names = row[:closes].split
            mine = key(row, opener, 0).to_s[0, 7]
            events.select { |event| names.include?(qualified(event)) && key(row, event, 1).to_s[0, 7] == mine }
          end

          # The key of an event: its id, or the link the join names at `side` (0 the opener's).
          def key(row, event, side)
            return event[:id] if row[:joins] == "id"

            (event[:links] || {})[row[:joins].split[side]].to_s
          end

          def readable?(row, opener) = row[:joins] == "id" || key(row, opener, 0).match?(SHA)

          def entry(event, key) = { key: key, at: event[:at] }

          def qualified(event) = "#{event[:aggregate]}.#{event[:name]}"
        end
      end
    end
  end
end
