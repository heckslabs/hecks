# frozen_string_literal: true

module Hecks
  module Adapters
    # The one rule that says whether a work item may start with others already started: the
    # `WorkLimits` port asks it after a start.
    #
    # A work item that is neither red nor expedited counts only the other such holders against the
    # cap. A red one ({red?}) may also take up to `reserve` places beyond the cap, so the fix of a
    # red main starts when the cap is full, and a second red one waits once the reserve is
    # spent. An expedited one ({expedited?}) takes the one place outside the cap and the
    # reserve when no other expedited item holds it. Each further expedited item takes a regular
    # seat under the cap, ahead of normal work in the plan's order, and waits only when none is
    # free (ADR 0224). {seats} counts those seats.
    module WorkSlots
      # The reserve when none is declared.
      DEFAULT_RESERVE = 1

      # The key prefix of a work item that says main is red.
      RED = "red-"

      # The priority `Work.expedite!` sets: the lane outside the cap (ADR 0224).
      EXPEDITE = "expedite"

      module_function

      # @param item [#key, #title, #priority] the work item that would start
      # @param holders [Array<#key, #title, #priority>] the other work items already started or
      #   chosen
      # @param cap [Integer] the cap on started work items
      # @param reserve [Integer] the places beyond the cap that red work items may fill
      # @return [Boolean] whether the work item is held back
      def full?(item, holders, cap:, reserve:)
        return expedited_full?(holders, cap) if expedited?(item)
        return seats(holders) >= cap + reserve if red?(item)

        regular(holders) >= cap
      end

      # @param items [Array<#key, #title, #priority>] started or chosen work items
      # @return [Integer] the places they take under the cap: every item that is not expedited,
      #   and every expedited one but the first, which holds the place outside it
      def seats(items) = items.count { |other| !expedited?(other) } + extra_expedited(items)

      # An expedited item waits only when another holds the place outside the cap and no regular
      # seat is free.
      def expedited_full?(holders, cap)
        holders.any? { |other| expedited?(other) } && regular(holders) >= cap
      end

      # The regular seats taken: items that are neither red nor expedited, and the further
      # expedited ones.
      def regular(holders) = holders.count { |other| !urgent?(other) } + extra_expedited(holders)

      def extra_expedited(items) = [items.count { |other| expedited?(other) } - 1, 0].max

      # @param item [#key, #title, #priority] a work item
      # @return [Boolean] whether it is red, a `red-` key: it may spend the reserve
      def red?(item) = item.key.start_with?(RED)

      # @param item [#key, #title, #priority] a work item
      # @return [Boolean] whether it is expedited and not red: it takes the one place outside the
      #   cap
      def expedited?(item) = !red?(item) && item.priority.to_s == EXPEDITE

      # @param item [#key, #title, #priority] a work item
      # @return [Boolean] whether it is red or expedited
      def urgent?(item) = red?(item) || expedited?(item)
    end
  end
end
