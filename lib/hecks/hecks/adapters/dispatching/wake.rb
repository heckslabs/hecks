# frozen_string_literal: true

require_relative "parking"
require_relative "pending"

module Hecks
  module Adapters
    class Dispatching
      # Says whether the clock alone has made something eligible to start. Every other reason to
      # roll is an event: a run ends, work is planned, a branch lands. Three things become
      # eligible with no event at all, and a roll that waits for an unrelated event would leave
      # them waiting:
      #
      # - a yielded item's retry time passes (a backoff, or the hour a missing Passage parks it);
      # - the boot budget that stopped every start frees as hours leave its window;
      # - a roll was refused because a filling was running, and what that filling freed was lost.
      #
      # The beat asks this each time, in this process, so a quiet beat costs a read of the planned
      # items and starts no filling.
      module Wake
        module_function

        # @param items [Array<#key, #yield_kind, #retry_at>] the planned work items
        # @param now [Time] the time to judge against
        # @param stopped [#call] answers why the boot budget stops every start, or nil when it does
        #   not; asked only when the last plan was stopped by it
        # @return [String, nil] why the queue should roll now, nil on a quiet beat
        def reason(items, now:, stopped:)
          since = Pending.looked_at || Time.at(0).utc
          Pending.looked_at = now
          retry_reason(items, since, now) || budget_reason(stopped) || deferred_reason
        end

        # A retry time that passed since the last look. A time that passed earlier was seen by an
        # earlier look, and an item still waiting for room is not woken again every beat.
        def retry_reason(items, since, now)
          found = items.find { |item| (due = retry_time(item)) && due > since && due <= now }
          "the retry time of #{found.key} has passed" if found
        end

        def retry_time(item)
          Parking.parse(item.retry_at) if %w[transient missing_passage].include?(item.yield_kind.to_s)
        end

        def budget_reason(stopped)
          return unless Pending.budget_stopped
          return if stopped.call

          Pending.budget_stopped = false
          "the boot budget is no longer spent"
        end

        def deferred_reason = ("a roll was refused while a filling ran" if Pending.take_deferred!)
      end
    end
  end
end
