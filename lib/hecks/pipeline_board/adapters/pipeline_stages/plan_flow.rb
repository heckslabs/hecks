# frozen_string_literal: true

require_relative "throughput_days"

module Hecks
  module Adapters
    module PipelineBoard
      # How the plan moves: the Work items planned, finished and dropped on each of the last days,
      # the rate of each over the days before today, and what those rates do to the open items.
      # A plan that takes in more than it closes grows however much is finished, so the page says
      # which way it is going and, when it shrinks, how long it takes to clear.
      module PlanFlow
        # What the Tickets store's events are counted as.
        KINDS = %i[planned finished dropped].freeze

        module_function

        # @param times [Hash, nil] `planned`, `finished` and `dropped`, each the times of those
        #   events, or `{unknown: reason}`
        # @param now [Time]
        # @param open [Integer] the Work items open now
        # @return [Hash] `days` (oldest first: `day`, `label` and a count for each kind), `rates`
        #   (a day, for each kind, over the days before today), `net` (how many the plan grows by
        #   a day, negative when it shrinks), `open` and `clears_in` (days, nil while the plan does
        #   not shrink), or `{unknown: reason}` when the events were not read
        def build(times, now, open)
          return times || { unknown: "the plan's events were not read" } unless readable?(times)

          days = days_of(times, now)
          rates = rates_of(days[0...-1])
          net = (rates[:planned] - rates[:finished] - rates[:dropped]).round(1)
          { days: days, rates: rates, net: net, open: open, clears_in: clears_in(open, net) }
        end

        # @return [Array<Hash>] each of the days shown with its counts, oldest first
        def days_of(times, now)
          counts = KINDS.to_h { |kind| [kind, tally(times[kind], now)] }
          ThroughputDays.window(now).map { |date| day(date, counts) }
        end

        def readable?(times) = times.is_a?(Hash) && !times.key?(:unknown)

        # @return [Hash{Date => Integer}] how many of the times fall on each calendar day
        def tally(times, now) = Array(times).filter_map { |at| ThroughputDays.day_of(at, now) }.tally

        def day(date, counts)
          KINDS.to_h { |kind| [kind, counts[kind].fetch(date, 0)] }.merge(day: date.iso8601, label: date.strftime("%a %-d"))
        end

        # @return [Hash{Symbol => Float}] each kind's count a day, over the days given
        def rates_of(days)
          KINDS.to_h { |kind| [kind, days.empty? ? 0.0 : (days.sum { |day| day[kind] }.to_f / days.size).round(1)] }
        end

        # @return [Integer, nil] the days the open items take to clear while the plan shrinks
        def clears_in(open, net) = net.negative? ? (open / -net).ceil : nil
      end
    end
  end
end
