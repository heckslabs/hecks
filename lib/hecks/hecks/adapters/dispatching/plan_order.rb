# frozen_string_literal: true

module Hecks
  module Adapters
    class Dispatching
      # The order planned work items are listed in: a red one first, then a filed stall, then one
      # whose last yield a fill restarts first, then the rest. Inside a group the order is the
      # priority, then the epic's tier, then the plan step, then the key. It is mixed into {WorkItems}, whose
      # `find`, `red?` and `first_kinds` it uses.
      module PlanOrder
        # The urgency of a planned work item whose last yield a fill restarts first.
        RESTARTED = 2

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
          return 1 if marks[:stalls].any? { |prefix| item.key.start_with?(prefix) }

          marks[:first].include?(item.yield_kind.to_s) ? RESTARTED : RESTARTED + 1
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
