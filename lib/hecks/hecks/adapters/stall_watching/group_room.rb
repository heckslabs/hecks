# frozen_string_literal: true

module Hecks
  module Adapters
    class StallWatching
      # How many more stalls each capped `shares` group may file now: its rows' `cap` less its open
      # stalls. A stall stands open while it is filed, not abandoned, and its work item is not
      # settled by its row's `settled_by` lines on the stall key. A group with no cap is unbounded.
      class GroupRoom
        # @param kinds [Array<Hash>] the `StallKind` rows of the open lines
        # @param standing [Standing] what the tap says was abandoned and settled
        # @param lines [Array<Hash>] tap lines in sequence order, read for the filed stalls
        def initialize(kinds, standing, lines)
          @standing = standing
          @capped = kinds.uniq.select { |kind| kind[:cap].to_i.positive? && !kind[:shares].to_s.empty? }
          @filed = lines.filter_map { |line| line["id"].to_s if filed?(line) }.uniq
          @left = rooms
        end

        # Takes one place in the group, when it has room.
        #
        # @param group [String] a `shares` group
        # @return [Boolean] whether the group had room; a group with no cap always has
        def take?(group)
          return true unless @left.key?(group)
          return false unless @left[group].positive?

          @left[group] -= 1
          true
        end

        private

        def rooms
          caps = @capped.to_h { |kind| [kind[:shares].to_s, kind[:cap].to_i] }
          caps.to_h { |group, cap| [group, cap - open_in(group)] }
        end

        def filed?(line) = line["kind"] == "event" && line["event"] == "StallFiled"

        def open_in(group)
          rows = @capped.select { |kind| kind[:shares].to_s == group }
          @filed.count do |stall|
            kind = rows.find { |row| stall.start_with?("stall-#{row[:kind]}-") }
            kind && open?(kind, stall)
          end
        end

        def open?(kind, stall) = !@standing.abandoned?(stall) && !@standing.settled(kind, stall, "", nil)
      end
    end
  end
end
