# frozen_string_literal: true

module Hecks
  module Adapters
    class Dispatching
      # A {Plan}'s sprint rule, on when its `sprint:` limit is set: a work item starts only when it
      # is in the open sprint, is a bug, or is the fix of a red main. An item in no sprint waits as
      # "not in the open sprint", so with no open sprint only bugs start. A work item's `sprint`
      # holds the open sprint it is scheduled into; closing a sprint frees its items, and one
      # freed a moment late may start in that moment.
      #
      # Bugs hold {BUG_PLACES} place in all, started and chosen together, while a sprint item that
      # is not held is ready to start; with none ready, more bugs start.
      module PlanSprint
        # The refusal of a work item outside the open sprint.
        NOT_IN_SPRINT = "skipped: not in the open sprint"

        # The places bugs hold in all while a sprint item is ready.
        BUG_PLACES = 1

        # The category a bug carries.
        BUG = "bug"

        private

        # What stops an item, in order: the sprint, what holds it, the bug seat, the stops, the limits.
        def first_reason(item)
          sprint_reason(item) || held_reason(item) || bug_reason(item) || stop_reason(item) || limit_reason(item)
        end

        def sprint_reason(item)
          return unless @limits[:sprint]
          return if WorkItems.red?(item) || bug?(item) || in_sprint?(item)

          NOT_IN_SPRINT
        end

        # A bug beyond the bug place waits while a sprint item is ready.
        def bug_reason(item)
          return unless @limits[:sprint] && bug?(item) && sprint_ready?

          held = holders.select { |other| bug?(other) }
          "skipped: held: bug #{held.first.key} already holds the one bug seat" if held.size >= BUG_PLACES
        end

        def sprint_ready?
          @sprint_ready = @planned.any? { |item| in_sprint?(item) && !bug?(item) && !held_reason(item) } if @sprint_ready.nil?
          @sprint_ready
        end

        def bug?(item) = item.category.to_s == BUG

        def in_sprint?(item) = !item.sprint.to_s.empty?
      end
    end
  end
end
