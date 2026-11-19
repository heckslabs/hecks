# frozen_string_literal: true

module Hecks
  module Adapters
    class Dispatching
      # The order planned work items are listed in: a red one first, then an expedited one, then
      # one whose last yield a
      # fill restarts first, then one of priority `now`, then a filed stall, then the rest. A stall
      # never ranks ahead of priority-now work, so it cannot take the free places an urgent fix
      # needs. Inside a group the order is the priority, then the epic's tier, then the plan step,
      # then the key. It is mixed into
      # {WorkItems}, whose `find`, `red?`, `expedited?` and `first_kinds` it uses.
      module PlanOrder
        # The urgency of an expedited work item: after a red one, ahead of everything else.
        EXPEDITED = 1

        # The urgency of a planned work item whose last yield a fill restarts first.
        RESTARTED = 2

        # The urgency of a planned work item of priority `now` that is not a filed stall.
        URGENT = 3

        # The urgency of a filed stall's item, after red, restarted and priority-now work: the
        # last urgency a roll starts by itself.
        STALLED = 4

        # @param key [String] a work item's key
        # @return [Boolean] whether it is a filed stall's item: its key starts `stall-<kind>-` for a
        #   kind the StallWatch bluebook's `StallKind` rows declare
        def stall_item?(key) = stall_prefixes.any? { |prefix| key.to_s.start_with?(prefix) }

        private

        # An item restarted first ranks by its priority alone, whatever its epic's tier: the tier is
        # zeroed so it never separates two of them.
        def order(entry, index, marks)
          step, rank, item = entry
          urgency = urgency(item, marks)
          [urgency, urgency == RESTARTED ? [rank.first, 0] : rank, step, item.key, index]
        end

        def urgency(item, marks)
          return 0 if red?(item)
          return EXPEDITED if expedited?(item)
          return STALLED if marks[:stalls].any? { |prefix| item.key.start_with?(prefix) }
          return RESTARTED if marks[:first].include?(item.yield_kind.to_s)

          item.priority == "now" ? URGENT : STALLED + 1
        end

        # Read once for a listing: the stall prefixes and the yield kinds restarted first.
        def urgent_marks = { stalls: stall_prefixes, first: first_kinds }

        # The key prefix of each kind of stall the StallWatch bluebook's `StallKind` rows declare,
        # `stall-<kind>-`, so a planned work item merely named `stall-...` ranks as any other.
        def stall_prefixes
          rows = find("Hecks", "StallWatch")&.value_objects&.find { |object| object.hecks_name == "StallKind" }
          Array(rows&.members).map { |row| "stall-#{row[:kind]}-" }
        end
      end
    end
  end
end
