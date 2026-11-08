# frozen_string_literal: true

require_relative "../area_overlap"

module Hecks
  module Adapters
    class Dispatching
      # Which planned work items start a session now, and why each of the others waits. It decides
      # from
      # the
      # work items it is given and starts nothing.
      #
      # A planned work item waits when it sits in a frozen area, when its area overlaps a started
      # work item's or
      # an
      # earlier chosen work item's (by {AreaOverlap}), or when the machine is loaded or the cap is
      # reached,
      # which also hold back every work item after it.
      class Plan
        # A work item, as {WorkItems} reads it.
        Item = Struct.new(:key, :title, :detail, :area, keyword_init: true)

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
        # @param limits [Hash] `cap:` (Integer), `load:` and `max_load:` (Float), `frozen:` (Array)
        #   and `paused:` (String, optional: why every work item waits, "skipped: paused by load")
        #   and `root:` (String, optional: this repository's top level, to tell its areas from another
        #   checkout's; the checkout holding this file by default)
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

        private

        def consider(item)
          reason = stop_reason || frozen_reason(item) || overlap_reason(item)
          reason ? @skipped << Skip.new(item.key, reason) : @chosen << item
        end

        def stop_reason = @limits[:paused] || overloaded || capped

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
