# frozen_string_literal: true

require_relative "../area_overlap"
require_relative "parking"

module Hecks
  module Adapters
    class Dispatching
      # Which planned work items start a session now, and why each of the others waits. It decides
      # from
      # the
      # work items it is given and starts nothing.
      #
      # A planned work item waits when its last yield parked it ({Parking}), when it sits in a
      # frozen area, when its area overlaps a started
      # work item's or
      # an
      # earlier chosen work item's (by {AreaOverlap}), or when the machine is loaded or the cap is
      # reached,
      # which also hold back every work item after it.
      class Plan
        # A work item, as {WorkItems} reads it.
        # `yield_kind`, `retry_at` and `yield_count` are what its last yield recorded ({Parking}).
        Item = Struct.new(:key, :title, :detail, :area, :yield_kind, :retry_at, :yield_count, :priority,
                          :epic, keyword_init: true)

        # The top level of this checkout: the root an absolute area is made relative to.
        REPOSITORY = File.expand_path("../../../../..", __dir__)

        # What a name is compared without, so `quality_control` and `QualityControl` meet.
        NOT_ALNUM = /[^a-z0-9]/

        # A work item left waiting, and the reason.
        Skip = Struct.new(:key, :reason)

        # @return [Array<Item>] the work items to start, in plan order
        attr_reader :chosen

        # @return [Array<Skip>] the work items left waiting, in plan order
        attr_reader :skipped

        # @param planned [Array<Item>] the planned work items, in plan order
        # @param started [Array<Item>] the started work items
        # @param limits [Hash] `runs:` (callable answering the AgentRun states by run key, optional)
        #   and `now:` (Time, optional), `cap:` (Integer), `load:` and `max_load:` (Float),
        #   `frozen:` (Array), `epic_wip:` (Integer, optional: most started items of one epic)
        #   and `paused:` (String, optional: why every work item waits, "skipped: paused by load")
        #   and `budget:` (String, optional: why every work item waits once the boots spent their
        #   budget)
        #   with `rethinks:` (callable, optional: answers why a work item waits for a person)
        #   with `exempt:` (callable, optional: answers whether a work item starts despite it)
        #   and `root:` (String, optional: this repository's top level, to tell its areas from
        #   another checkout's; the checkout holding this file by default)
        def initialize(planned, started, **limits)
          @started = started
          @limits = limits
          @chosen = []
          @skipped = []
          planned.each { |item| consider(item) }
        end

        # @return [Array<Item>] the started work items and the chosen ones: whose areas are not to
        #   be
        #   edited
        def holders = @started + @chosen

        # @return [String, nil] why the boot budget held every start back, nil when it did not
        def budget_stop = @limits[:budget]

        # Whether the machine, not the queue, left a work item waiting: the load average was over
        # its limit or the machine's crossings paused every start. Such a wait ends when the
        # machine recovers, which may not cross a mark, so the clock's beat watches for it.
        #
        # @return [Boolean]
        def held_by_machine?
          @skipped.any? { |skip| skip.reason == @limits[:paused] || skip.reason.start_with?("skipped: load") }
        end

        private

        def consider(item)
          reason = rethink_reason(item) || parked_reason(item) || stop_reason(item) || frozen_reason(item) || epic_reason(item) ||
                   overlap_reason(item)
          reason ? @skipped << Skip.new(item.key, reason) : @chosen << item
        end

        # A work item the architect said to rethink too often waits for a person.
        def rethink_reason(item) = @limits[:rethinks]&.call(item.key)

        # A yielded item waits out its backoff or its blocker, and does not count against the cap.
        def parked_reason(item)
          Parking.reason(item, runs: @limits[:runs] || -> { {} }, now: @limits[:now] || Time.now.utc)
        end

        def stop_reason(item) = @limits[:paused] || budget_reason(item) || overloaded || capped

        # A spent boot budget holds back every work item but the ones `exempt:` names, so the fix
        # of a red main still starts.
        def budget_reason(item)
          @limits[:budget] unless @limits[:exempt]&.call(item)
        end

        # The backstop: the load average alone refuses a fill, whatever the events said.
        def overloaded
          return unless @limits[:load] > @limits[:max_load]

          "skipped: load #{@limits[:load].round(1)} > #{@limits[:max_load].round(1)}"
        end

        def capped
          return unless holders.size >= @limits[:cap]

          "skipped: cap #{@limits[:cap]} reached (#{@started.size} started, #{@chosen.size} chosen by this fill)"
        end

        def frozen_reason(item)
          hit = @limits[:frozen].find { |name| item.area.any? { |word| squash(word).include?(squash(name)) } }
          "skipped: frozen (#{hit})" if hit
        end

        # An epic holding its limit of work items, started or chosen by this fill, holds the next
        # one back. A work item with no epic, and the fix of a red main, are not held.
        def epic_reason(item)
          limit = @limits[:epic_wip]
          return if limit.nil? || item.epic.to_s.empty? || @limits[:exempt]&.call(item)

          count = holders.count { |other| other.epic == item.epic }
          "skipped: held: epic #{item.epic} already has #{count} started" if count >= limit
        end

        def overlap_reason(item)
          holders.each do |other|
            pair = AreaOverlap.first_overlap(item.area, other.area, root: root)
            return "skipped: #{pair[0]} overlaps #{other.key} at #{pair[1]}#{places(pair)}" if pair
          end
          nil
        end

        def root = @limits[:root] || REPOSITORY

        # Whose repository each side of a clash is, said only when the two differ.
        def places(pair)
          mine, theirs = pair.map { |area| AreaOverlap.outside?(area, root: root) }
          return "" if mine == theirs

          " (#{pair[0]} is in #{place(mine)}, #{pair[1]} is in #{place(theirs)})"
        end

        def place(outside) = outside ? "another checkout" : "this repository"

        def squash(text) = text.to_s.downcase.gsub(NOT_ALNUM, "")
      end
    end
  end
end
