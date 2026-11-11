# frozen_string_literal: true

require "etc"
require_relative "../work_limits"
require_relative "../boot_budget"
require_relative "../shell"
require_relative "../../../rust_build/session_build"
require_relative "../codebase/test_scope"
require_relative "../machine_sampling/history"
require_relative "rethinks"

module Hecks
  module Adapters
    class Dispatching
      # What the Tickets world says about filling the queue, and what the machine says about its
      # load. The bluebook never reads the OS, so the load and the CPU count come through here.
      class Settings
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
          @load = load || -> { self.class.uptime_load }
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

        # @return [Float] the 1-minute load average now
        def load = @load.call.to_f

        # @return [Integer] the CPU count
        attr_reader :cpus

        # @return [Float] the load above which no session is started: the world's, else the CPU
        #   count
        def max_load = (declared(MAX_LOAD)[:limit] || @cpus).to_f

        # @return [String, nil] why no session starts while the machine's crossings say so: the
        #   last reading left the load above its mark ("paused by load") or memory low; else nil
        def paused
          standing = MachineSampling::History.new(@registry).states
          return "skipped: paused by load (LoadRoseAbove)" if standing[:load] == "above"

          "skipped: memory low (MemoryLow)" if standing[:memory] == "low"
        end

        # @return [Float, nil] the hours of launcher boots a day the world allows, nil for none
        def boot_budget = declared(BOOT_BUDGET)[:boot_hours_per_day]&.to_f

        # @return [String, nil] why no session starts: the day's boots have spent the world's
        #   budget; nil when they have not, or the world sets none
        def boot_stop
          hours = boot_budget
          @boots.stop_reason(hours) if hours
        end

        # @return [Time, nil] when the oldest counted boots leave the window far enough to free the
        #   budget; nil when the world sets no budget or the window alone cannot free it
        def boot_frees_at
          hours = boot_budget
          @boots.frees_at(hours) if hours
        end

        # @return [Integer] the seconds a started session is given to appear in the listing
        def session_grace = Integer(declared(GRACE)[:seconds] || GRACE_SECONDS)

        # @return [Integer] the architect rethinks that stop a Work item for a person
        def rethink_limit = Integer(declared("rethink_limit")[:limit] || Rethinks::LIMIT)

        # @return [Boolean] whether planned work rolls forward by itself; false only when paused
        def roll_forward? = declared(ROLL)[:roll_forward] != false

        # @return [Integer] the cap on started work items
        def cap = @cap || WorkLimits.cap(@registry)

        # @return [Integer, nil] the most spec files a session may run per call, from the Hecks
        #   world's `test_scope` setting; nil when none is declared
        def spec_files_limit = Codebase::TestScope.limit(@registry)

        # @return [Hash{String => String}] the environment every dispatched session starts with
        def session_environment = RustBuild::SessionBuild.environment_of(declared(SESSION))

        # @return [Integer, nil] the `nice` increment for a session's processes, nil for none
        def nice = RustBuild::SessionBuild.nice_of(declared(SESSION))

        private

        def declared(verb) = @registry&.world("Tickets")&.for_verb(verb) || {}
      end
    end
  end
end
