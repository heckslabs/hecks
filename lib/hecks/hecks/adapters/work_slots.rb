# frozen_string_literal: true

module Hecks
  module Adapters
    # The one rule that says whether a work item may start with others already started. The
    # dispatch plan asks it before a start and the `WorkLimits` port asks it after, so the two
    # cannot disagree and a started item is never yielded straight back.
    #
    # A work item that is neither red nor expedited counts only the other such holders against the
    # cap. A red one (`WorkItems.red?`) may also take up to `reserve` places beyond the cap, so the
    # fix of a red main starts when the cap is full, and a second red one waits once the reserve is
    # spent. An expedited one (`WorkItems.expedited?`) takes the one place outside the cap and the
    # reserve: it waits only while another expedited item holds that place (ADR 0222).
    module WorkSlots
      # The reserve when none is declared: the plan and the `WorkLimits` port both fall back to it.
      DEFAULT_RESERVE = 1

      module_function

      # @param item [#key, #title, #priority] the work item that would start
      # @param holders [Array<#key, #title, #priority>] the other work items already started or
      #   chosen
      # @param cap [Integer] the cap on started work items
      # @param reserve [Integer] the places beyond the cap that red work items may fill
      # @return [Boolean] whether the work item is held back
      def full?(item, holders, cap:, reserve:)
        return holders.any? { |other| expedited?(other) } if expedited?(item)
        return holders.count { |other| !expedited?(other) } >= cap + reserve if red?(item)

        holders.count { |other| !Dispatching::WorkItems.urgent?(other) } >= cap
      end

      # @param item [#key, #title, #priority] a work item
      # @return [Boolean] whether it is red: it may spend the reserve
      def red?(item) = Dispatching::WorkItems.red?(item)

      # @param item [#key, #title, #priority] a work item
      # @return [Boolean] whether it is expedited: it takes the one place outside the cap
      def expedited?(item) = Dispatching::WorkItems.expedited?(item)
    end
  end
end
