# frozen_string_literal: true

require_relative "group_room"

module Hecks
  module Adapters
    class StallWatching
      # The `shares` and `cap` rules of the `StallKind` rows: rows that name one group file at
      # most one stall per subject, so one stalled item wakes one session. A subject is taken while
      # a row of its group holds a filed, not abandoned stall whose line is still open; otherwise
      # the first row of the group, in declared order, that is past its minutes files and the later
      # ones wait. A row not past its minutes takes nothing, so a young row never hides a ready one.
      # A group whose rows name a `cap` files no more while that many stalls stand open
      # ({GroupRoom}).
      class SharedSubjects
        # @param entries [Array<Array>] every open line as `[kind, subject, at, branch]`, in the
        #   rows' declared order
        # @param standing [Standing] what the tap says was filed and abandoned
        # @param key [#call] answers a kind and subject's stall key
        # @param lines [Array<Hash>] tap lines in sequence order, read for the open stalls
        def initialize(entries, standing, key, lines = [])
          @groups = entries.to_h { |kind, *| [kind[:kind], kind[:shares].to_s] }
          @taken = entries.filter_map do |kind, subject, *|
            stall = key.call(kind, subject)
            [kind[:shares].to_s, subject] if standing.filed?(stall) && !standing.abandoned?(stall)
          end.to_set
          @room = GroupRoom.new(entries.map(&:first), standing, lines)
        end

        # @param rows [Array<Hash>] `Sighting` rows in the rows' declared order
        # @return [Array<Hash>] the rows, less each row whose group already holds its subject, and
        #   each ready row past its group's cap
        def keep(rows)
          claimed = Set.new
          rows.reject do |row|
            group = [@groups[row[:stall_kind]].to_s, row[:subject]]
            next false if group.first.empty?
            next true if @taken.include?(group) || claimed.include?(group)

            ready?(row) && !claim?(group, claimed)
          end
        end

        private

        # Takes the subject for a ready row; false when its group's cap leaves no room.
        def claim?(group, claimed)
          return false unless @room.take?(group.first)

          claimed << group
          true
        end

        def ready?(row) = row[:waited] >= row[:minutes].to_i
      end
    end
  end
end
