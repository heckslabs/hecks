# frozen_string_literal: true

module Hecks
  module Adapters
    # The one rule that says whether a work item may start with others already started. The
    # dispatch plan asks it before a start and the `WorkLimits` port asks it after, so the two
    # cannot disagree and a started item is never yielded straight back.
    #
    # A work item that is not red counts only the non-red holders against the cap. A red one
    # (`WorkItems.red?`) may also take up to `reserve` places beyond the cap, so the fix of a red
    # main starts when the cap is full, and a second red one waits once the reserve is spent.
    module WorkSlots
      module_function

      # @param item [#key, #title] the work item that would start
      # @param holders [Array<#key, #title>] the other work items already started or chosen
      # @param cap [Integer] the cap on started work items
      # @param reserve [Integer] the places beyond the cap that red work items may fill
      # @return [Boolean] whether the work item is held back
      def full?(item, holders, cap:, reserve:)
        return holders.size >= cap + reserve if Dispatching::WorkItems.red?(item)

        holders.count { |other| !Dispatching::WorkItems.red?(other) } >= cap
      end
    end
  end
end
