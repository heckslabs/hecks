# frozen_string_literal: true

module Hecks
  module Adapters
    class Velocity
      # The text of a day's velocity: a line per finished work item, then the recorded,
      # inferred and total hours. Every inferred figure carries the word inferred.
      class Text
        # Minutes in one pomodoro, and in one hour.
        ROUND = 25
        HOUR = 60.0

        # @param day [String] the ISO date
        # @param items [Array<Hash>] `key:`, `title:` and `spent:` (pomodoros) or `span:` (seconds)
        def initialize(day, items)
          @day = day
          @items = items
        end

        # @return [String] the report, ending in a newline
        def to_s
          lines = @items.map { |item| line(item) }
          ["Velocity #{@day} (the day's sprint):", *lines.map { |text| "  #{text}" }, *totals].join("\n") << "\n"
        end

        private

        def recorded?(item) = item[:spent].to_i.positive?

        def hours(item) = recorded?(item) ? item[:spent] * ROUND / HOUR : item[:span]&.fdiv(3600)

        def line(item)
          head = "#{item[:key]}: #{item[:title]} - "
          return "#{head}#{format("%.1f", hours(item))} h (#{item[:spent]} pomodoros)" if recorded?(item)

          figure = item[:span] ? "#{format("%.1f", hours(item))} h" : "unknown"
          "#{head}#{figure} INFERRED"
        end

        def totals
          kept, guessed = @items.partition { |item| recorded?(item) }
          ["Recorded: #{sum(kept)} h", "INFERRED: #{sum(guessed)} h", "Total: #{sum(@items)} h"]
        end

        def sum(items) = format("%.1f", items.sum { |item| hours(item) || 0 })
      end
    end
  end
end
