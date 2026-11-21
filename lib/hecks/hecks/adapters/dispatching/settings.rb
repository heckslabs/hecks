# frozen_string_literal: true

require "etc"
require_relative "window_standing"
require_relative "../work_limits"
require_relative "../boot_budget"
require_relative "../shell"
require_relative "../claude_executable"
require_relative "../../../rust_build/session_build"
require_relative "../codebase/test_scope"
require_relative "../machine_sampling/history"
require_relative "rethinks"
require_relative "meter_switch"
require_relative "batching"
require_relative "boot_guard"

module Hecks
  module Adapters
    class Dispatching
      # What the Tickets world says about filling the queue, and what the machine says about its
      # load. The bluebook never reads the OS, so the load and the CPU count come through here.
      class Settings
        include BootGuard

        # The world verb naming the areas and aggregates whose persisted shape may not move.
        FREEZE = "frozen_shapes"

        # The world verb that carries the highest 1-minute load a session may be started under.
        MAX_LOAD = "dispatch_max_load"

        # The world verb that carries what every session starts with.
        SESSION = "session_environment"

        # The world verb that carries the owner's roll-forward switch.
        ROLL = "dispatch_roll_forward"

        # The world verb that carries the hours of launcher boots a day allows.
        BOOT_BUDGET = "cpu_budget"

        # The world verb that carries how long a started session may go unlisted before it is
        # taken for gone.
        GRACE = "session_grace"

        # The world verb that carries the minutes a started run may show no sign of life before it
        # is taken for gone when `claude` cannot be asked.
        GONE = "run_gone_after"

        # The world verb that carries where `claude` is installed, tried when `PATH` has none.
        EXECUTABLE = "claude_executable"

        # The world verb that carries the minutes a `stopped` session may stand over a started run
        # that shows no sign of life before the run is taken for gone.
        STOPPED = "stopped_session_after"

        # Minutes a started run may show nothing when the world names none.
        GONE_MINUTES = 60

        # The world verb that carries the most started work items of one epic.
        EPIC_WIP = "epic_wip_limit"

        # Started work items of one epic allowed at once when the world names no limit.
        EPIC_WIP_LIMIT = 2

        # The world verb that carries the bounds on shedding load.
        SHED = "load_shed"

        # Coders that must run before one is asked to yield, when the world names none.
        SHED_MIN_CODERS = 2

        # Runs that may stand asked to yield at once, when the world names none.
        SHED_AT_ONCE = 1

        # Seconds a session is given to appear in `claude agents` when the world names none.
        GRACE_SECONDS = 120

        # Minutes a started work item may run when the caller names no budget.
        BUDGET_MINUTES = 90

        # What `uptime` prints before the 1-minute load, on macOS and Linux.
        UPTIME_LOAD = /load averages?:\s*([0-9]+[.,][0-9]+)/

        # @param registry [Runtime::Registry, nil] the booted registry whose Tickets world is read
        # @param load [#call, nil] answers the 1-minute load average; the machine's when nil
        # @param cpus [Integer, nil] the CPU count; the machine's when nil
        # @param cap [Integer, nil] the cap on started work items; the world's when nil
        # @param boots [BootBudget, nil] what the day's boots cost; the usage record's when nil
        def initialize(registry, load: nil, cpus: nil, cap: nil, boots: nil)
          @registry = registry
          @load = load || method(:read_load)
          @cpus = cpus || Etc.nprocessors
          @cap = cap
          @boots = boots || BootBudget.new
        end

        # Ruby's `Etc` has no load average, so the 1-minute figure is read from `uptime`.
        #
        # @param text [String, nil] what `uptime` printed; the machine's when nil
        # @return [Float] the 1-minute load, 0.0 when `uptime` says none
        def self.uptime_load(text = nil)
          text ||= Shell.new.capture("uptime").out
          text[UPTIME_LOAD, 1].to_s.tr(",", ".").to_f
        end

        # @return [Array<String>] the frozen areas and aggregates, empty when none is declared
        def frozen = Array(declared(FREEZE)[:areas]).map(&:to_s)

        # @return [Float] the 1-minute load average now: Roundhouse's meter with the Tickets world's
        #   `metering.roundhouse` switch on, else `uptime`
        def load = @load.call.to_f

        # @return [String] where the last {#load} was read: `roundhouse`, or `uptime` with the
        #   switch off, a meter that could not read, or a stand-in load
        def load_source = @load_source || "uptime"

        # @return [Integer] the CPU count
        attr_reader :cpus

        # @return [Float] the load above which no session is started: the world's, else the CPU
        #   count
        def max_load = (declared(MAX_LOAD)[:limit] || @cpus).to_f

        # @return [String, nil] why no session starts while the machine's crossings say so: the
        #   last reading left the load above its mark ("paused by load") or memory low; else nil
        def paused
          standing = MachineSampling::History.new(@registry).states
          return Plan::LOAD_PAUSE if standing[:load] == "above"

          "skipped: memory low (MemoryLow)" if standing[:memory] == "low"
        end

        # @return [Float, nil] the hours of launcher boots a day the world declares, a reading for
        #   the board that holds nothing; nil for none
        def boot_budget = declared(BOOT_BUDGET)[:boot_hours_per_day]&.to_f

        # @return [BootBudget] what the day's boots cost, which protection reads too
        attr_reader :boots

        # @return [Integer] the seconds a started session is given to appear in the listing
        def session_grace = Integer(declared(GRACE)[:seconds] || GRACE_SECONDS)

        # @return [Integer] the minutes a started run may show no process, commit or change before
        #   it is gone, when `claude` cannot list sessions
        def run_gone_minutes = Integer(declared(GONE)[:minutes] || GONE_MINUTES)

        # @return [Integer] the minutes a session `claude` lists as stopped may stand over a started
        #   run that shows no process, commit or change before the run is gone
        def stopped_session_minutes = Integer(declared(STOPPED)[:minutes] || GONE_MINUTES)

        # @return [Array<String>] the places `claude` may be installed, the adapter's own when the
        #   world names none
        def claude_candidates = Array(declared(EXECUTABLE)[:candidates] || ClaudeExecutable::CANDIDATES)

        # @return [Boolean] whether `claude` is on `PATH` or at none of the declared places
        def claude_missing? = !ClaudeExecutable.new(candidates: claude_candidates).found?

        # @return [Integer] the architect rethinks that stop a Work item for a person
        def rethink_limit = Integer(declared("rethink_limit")[:limit] || Rethinks::LIMIT)

        # @return [Integer] the most work items of one epic started at once
        def epic_wip_limit = Integer(declared(EPIC_WIP)[:limit] || EPIC_WIP_LIMIT)

        # @return [Integer] the most work items one batch holds, its lead included: the Tickets
        #   world's `work_group_cap` `cap:`, else {Batching::CAP}
        def batch_cap = Integer(declared("work_group_cap")[:cap] || Batching::CAP)

        # @return [Integer] the fewest coders that must be running for one to be asked to yield
        def shed_min_coders = Integer(declared(SHED)[:min_coders] || SHED_MIN_CODERS)

        # @return [Integer] the most runs that may stand asked to yield and not yet ended
        def shed_at_once = Integer(declared(SHED)[:at_once] || SHED_AT_ONCE)

        # @return [Boolean] whether planned work rolls forward by itself; false when the owner has
        #   paused it or a merge window is open
        def roll_forward? = declared(ROLL)[:roll_forward] != false && !WindowStanding.open?(@registry)

        # @return [Boolean] whether the owner's switch lets new work start, merge window aside
        def switch_on? = WorkLimits.switch_on?(@registry)

        # @return [Integer] the cap on started work items
        def cap = @cap || WorkLimits.cap(@registry)

        # @return [Integer] the places beyond the cap that red work items may fill
        def urgent_reserve = WorkLimits.urgent_reserve(@registry)

        # @return [Integer, nil] the most spec files a session may run per call, from the Hecks
        #   world's `test_scope` setting; nil when none is declared
        def spec_files_limit = Codebase::TestScope.limit(@registry)

        # @return [Hash{String => String}] the environment every dispatched session starts with
        def session_environment = RustBuild::SessionBuild.environment_of(declared(SESSION))

        # @return [Integer, nil] the `nice` increment for a session's processes, nil for none
        def nice = RustBuild::SessionBuild.nice_of(declared(SESSION))

        private

        # The meter's load with the switch on and a reading taken, else `uptime`'s.
        def read_load
          metered = MeterSwitch.on?(@registry) && MeterSwitch.load
          @load_source = metered ? "roundhouse" : "uptime"
          metered || self.class.uptime_load
        end

        def declared(verb) = @registry&.world("Tickets")&.for_verb(verb) || {}
      end
    end
  end
end
