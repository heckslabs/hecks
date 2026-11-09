# frozen_string_literal: true

require_relative "parking"
require_relative "pending"

module Hecks
  module Adapters
    class Dispatching
      # Says whether the clock alone has made something eligible to start. Every other reason to
      # roll is an event. Four things become eligible with no event, and a roll that waited for an
      # unrelated event would leave them waiting:
      #
      # - a yielded item's retry time passes (a backoff, or the hour a missing Passage parks it);
      # - the boot budget that stopped every start frees as hours leave its window;
      # - the load fell under its limit, or a pause ended, with no mark of the machine's crossed;
      # - a roll was refused because a filling was running, and what that filling freed was lost.
      #
      # A quiet beat costs a short-lived read of the planned items and starts no filling. The budget
      # is read only once it could have freed, and the load only while a filling stands held back.
      module Wake
        # Seconds before the budget is read again when the window alone cannot free it.
        BUDGET_RECHECK = 600

        module_function

        # @param items [Array<#key, #yield_kind, #retry_at>] the planned work items
        # @param now [Time] the time to judge against
        # @param stopped [#call] answers why the boot budget stops every start, or nil when it does
        #   not; asked only once the budget could have freed
        # @param frees_at [#call] answers when the oldest counted boots leave the window far enough
        #   to free the budget, or nil
        # @param cleared [#call] answers whether the machine has stopped holding a filling back: the
        #   load is under its limit and no crossing pauses the starts; asked only while held back
        # @return [String, nil] why the queue should roll now, nil on a quiet beat
        def reason(items, now:, stopped:, frees_at: -> {}, cleared: -> { false })
          since = Pending.looked_at || Time.at(0).utc
          Pending.looked_at = now
          retry_reason(items, since, now) || budget_reason(stopped, frees_at, now) || load_reason(cleared) ||
            deferred_reason
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

        # The budget only frees as old runs leave the window, since a new run adds hours, so it is
        # not read before the time the oldest counted runs leave; a read that finds it still spent
        # says when to read again.
        def budget_reason(stopped, frees_at, now)
          return unless Pending.budget_stopped
          return if Pending.budget_frees_at && now < Pending.budget_frees_at
          return await_budget(frees_at, now) if stopped.call

          Pending.budget_stopped = false
          "the boot budget is no longer spent"
        end

        def await_budget(frees_at, now)
          Pending.budget_frees_at = frees_at.call || (now + BUDGET_RECHECK)
          nil
        end

        # A filling held back by the load or a pause is not retried by an event, and the load can
        # fall without crossing a mark, so the beat watches for it to clear.
        def load_reason(cleared)
          return unless Pending.load_stopped
          return unless cleared.call

          Pending.load_stopped = false
          "the machine is no longer over its limit"
        end

        def deferred_reason = ("a roll was refused while a filling ran" if Pending.take_deferred!)
      end
    end
  end
end
