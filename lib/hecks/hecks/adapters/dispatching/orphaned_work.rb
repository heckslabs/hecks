# frozen_string_literal: true

require "time"

module Hecks
  module Adapters
    class Dispatching
      # The started work items that hold a place with nothing behind it: no run of theirs is live,
      # no landing of theirs is under way, and the dispatch itself claimed them a while ago.
      #
      # An item that dispatch just started has no run for a moment (the launcher starts the item,
      # then its run), a person's own claim has none at all, and an item whose branch was handed to
      # a landing job is waiting on it; none of those is an orphan, so each is left alone. A run row
      # that began before the item's claim belongs to an earlier start and does not count.
      class OrphanedWork
        # The work item's claimant when the dispatch started it.
        CLAIMANT = "dispatch"

        # The run states of the current start that a settle already reads: a started run is live and
        # a finished one is settled by the pass that follows its end.
        HANDLED = %w[started finished].freeze

        # @param work_items [WorkItems] answers `runs`, `claimant`, `claimed_at` and
        #   `landing_in_flight?`
        # @param min_age [Integer] seconds a claim must be old before its item can be an orphan
        # @param clock [#call] answers the time
        def initialize(work_items, min_age:, clock: -> { Time.now.utc })
          @work_items = work_items
          @min_age = min_age
          @clock = clock
        end

        # @param started [Array<#key>] the started work items
        # @return [Array<#key>] those that hold a place with no live run and no landing under way
        def among(started)
          runs = @work_items.runs
          started.select { |item| runless?(runs[item.key], item.key) && claimed_long_ago?(item.key) && !landing?(item.key) }
        end

        private

        def landing?(key) = @work_items.landing_in_flight?(key)

        def runless?(run, key) = !(HANDLED.include?(run&.dig(:status).to_s) && begun_since_claim?(run, key))

        def begun_since_claim?(run, key)
          Time.iso8601(run[:started_at].to_s) >= Time.iso8601(@work_items.claimed_at(key))
        rescue ArgumentError, TypeError
          false
        end

        def claimed_long_ago?(key)
          @work_items.claimant(key) == CLAIMANT && @clock.call - Time.iso8601(@work_items.claimed_at(key)) >= @min_age
        rescue ArgumentError
          false
        end
      end
    end
  end
end
