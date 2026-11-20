# frozen_string_literal: true

require_relative "../area_overlap"
require_relative "parking"
require_relative "../work_slots"
require_relative "pressure_limits"
require_relative "plan_admission"
require_relative "plan_batch"

module Hecks
  module Adapters
    class Dispatching
      # Which planned work items start a session now, and why each of the others waits. It decides
      # from the work items it is given and starts nothing.
      #
      # A planned work item waits when a work item it depends on has not landed ({Dependencies}),
      # when its last yield parked it ({Parking}), when it sits in a frozen area, when its area
      # overlaps a started work item's or an earlier chosen work item's (by {AreaOverlap}), or when
      # the load is over its limit or the cap is reached, which also hold back every work item after
      # it. A fill with free places starts as many startable work items as it has places: the load
      # limit is the machine's one stop, and the headroom estimate is reported, never held to.
      class Plan
        include PlanAdmission
        include PlanBatch

        # A work item, as {WorkItems} reads it.
        # `yield_kind`, `retry_at` and `yield_count` are what its last yield recorded ({Parking}).
        # `waits_on` is the work items it names as waited on ({Dependencies}), nil when not read.
        # `batch` is the lead whose batch holds it, and `batch_commit` its commit on the lead's
        # branch once built; a lead a fill starts for a group carries the work items it builds as
        # `batched` and the `group` it was asked for ({Batching}).
        Item = Struct.new(:key, :title, :detail, :area, :waits_on, :yield_kind, :retry_at, :yield_count, :priority,
                          :epic, :batch, :batch_commit, :batched, :group, keyword_init: true)

        # The top level of this checkout: the root an absolute area is made relative to.
        REPOSITORY = File.expand_path("../../../../..", __dir__)

        # What a name is compared without, so `quality_control` and `QualityControl` meet.
        NOT_ALNUM = /[^a-z0-9]/

        # The places filed stall items may hold in all, started and chosen together.
        STALL_PLACES = 1

        # The pause the load's crossing sets ({Settings#paused}), which an expedited item passes.
        LOAD_PAUSE = "skipped: paused by load (LoadRoseAbove)"

        # A work item left waiting, and the reason.
        Skip = Struct.new(:key, :reason)

        # @return [Array<Item>] the work items to start, in plan order
        attr_reader :chosen

        # @return [Array<Skip>] the work items left waiting, in plan order
        attr_reader :skipped

        # @param planned [Array<Item>] the planned work items, in plan order
        # @param started [Array<Item>] the started work items
        # @param limits [Hash] `runs:` (callable: AgentRun states by run key), `now:` (Time), `cap:`
        #   (Integer), `load:` and `max_load:` (Float), `frozen:` (Array), `epic_wip:` (most started
        #   items of one epic), `headroom:` and `per_session:` (the estimate reported),
        #   `urgent_reserve:` (red), `cpus:` (the load an expedited item may start under), `paused:`
        #   and `budget:` (String: why every work item waits), `rethinks:` (callable: why an item
        #   waits for a person), `waits:` (callable: the unlanded item it waits on), `admit:`
        #   ({PlanAdmission}), `exempt:` (callable: whether an item starts despite it), `stall:`
        #   (callable: whether a key is a filed stall's), `root:` (the repository's top level) and
        #   `effective:` (callable: its area now, by {EffectiveArea}); all optional but `cap:`,
        #   `load:`, `max_load:` and `frozen:`
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

        # @return [Integer, nil] the sessions the load had room for, an estimate the report states
        #   and the plan does not hold to; nil when no reading said
        def headroom = @limits[:headroom]

        # @return [Float, nil] the load one session is taken to cost, nil when no limit says
        def per_session = @limits[:per_session]

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
          reason = held_reason(item) || stop_reason(item) || limit_reason(item)
          reason ? @skipped << skip_of(item, reason) : @chosen << item
        end

        # What holds an item whatever room there is; such an item does not count against the cap.
        def held_reason(item) = rethink_reason(item) || dependency_reason(item) || parked_reason(item)

        # An item waits until each work item it names has landed, a red one included: it is never
        # chosen, so it is never started and yielded for a dependency.
        def dependency_reason(item) = @limits[:waits]&.call(item)

        # A work item the architect said to rethink too often waits for a person.
        def rethink_reason(item) = @limits[:rethinks]&.call(item.key)

        # A yielded item waits out its backoff or its blocker, and does not count against the cap.
        def parked_reason(item)
          Parking.reason(item, runs: @limits[:runs] || -> { {} }, now: @limits[:now] || Time.now.utc)
        end

        def stop_reason(item)
          return expedite_stop(item) if WorkItems.expedited?(item)

          @limits[:paused] || budget_reason(item) || overloaded(@limits[:max_load]) || capped(item)
        end

        # An expedited item passes the boot budget, a pause by load or by the short band, and the
        # load limit (ADR 0224): memory low, a load over the CPU count, or another expedited item
        # still holds it.
        def expedite_stop(item)
          pause = @limits[:paused]
          held = pause unless pause == LOAD_PAUSE || PressureLimits.pause?(pause)
          held || overloaded(@limits.fetch(:cpus, @limits[:max_load])) || expedite_held(item)
        end

        # The one place outside the cap is {WorkSlots}' rule; this names its holder.
        def expedite_held(item)
          return unless WorkSlots.full?(item, holders, cap: @limits[:cap], reserve: 0)

          "skipped: held: #{holders.find { |other| WorkItems.expedited?(other) }.key} holds the one expedite place"
        end

        # What the item's own place holds it: its area, its epic, or the one stall place.
        def limit_reason(item) = frozen_reason(item) || epic_reason(item) || stall_reason(item) || overlap_reason(item)

        # A spent boot budget holds back every work item but the ones `exempt:` names, so the fix
        # of a red main still starts.
        def budget_reason(item)
          @limits[:budget] unless @limits[:exempt]&.call(item)
        end

        # The backstop: the load average alone refuses a fill, whatever the events said.
        def overloaded(limit)
          return unless @limits[:load] > limit

          "skipped: load #{@limits[:load].round(1)} > #{limit.round(1)}"
        end

        # The cap and the red reserve are held by {WorkSlots}, the rule the `WorkLimits` port
        # applies to a start, so a chosen item is never yielded straight back.
        def capped(item)
          return admission_reason(item) if @limits[:admit]

          reserve = @limits[:urgent_reserve] || WorkSlots::DEFAULT_RESERVE
          return unless no_free_place? || WorkSlots.full?(item, holders, cap: @limits[:cap], reserve: reserve)

          "skipped: cap #{@limits[:cap]} reached (#{@started.size} started, #{@chosen.size} chosen by this fill)"
        end

        # A fill never starts more items than the cap has free places, a red one included; the red
        # reserve is spent only when no place is free. {WorkSlots} still holds the reserve itself.
        def no_free_place?
          free = @limits[:cap] - in_cap(@started)
          free.positive? && in_cap(@chosen) >= free
        end

        # The items that take a place under the cap: an expedited one takes the place outside it.
        def in_cap(items) = items.count { |other| !WorkItems.expedited?(other) }

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

        # Filed stall items, started or chosen by this fill, hold at most {STALL_PLACES} places, so
        # a run of stalls never takes the room a priority-now fix needs.
        def stall_reason(item)
          stall = @limits[:stall]
          return unless stall&.call(item.key)

          held = holders.select { |other| stall.call(other.key) }
          "skipped: held: stall #{held.first.key} already holds the one stall place" if held.size >= STALL_PLACES
        end

        def overlap_reason(item)
          holders.each do |other|
            pair = AreaOverlap.first_overlap(held_area(item), held_area(other), root: root)
            return "skipped: #{pair[0]} overlaps #{other.key} at #{pair[1]}#{places(pair)}" if pair
          end
          nil
        end

        # The ground an item holds now: what its branch changes once it has commits.
        def held_area(item) = @limits[:effective]&.call(item) || item.area

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
