# frozen_string_literal: true

require "etc"
require_relative "../work_limits"
require_relative "../shell"

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

        # Minutes a started row may run when the caller names no budget.
        BUDGET_MINUTES = 90

        # What `uptime` prints before the 1-minute load, on macOS and Linux.
        UPTIME_LOAD = /load averages?:\s*([0-9]+[.,][0-9]+)/

        # @param registry [Runtime::Registry, nil] the booted registry whose Tickets world is read
        # @param load [#call, nil] answers the 1-minute load average; the machine's when nil
        # @param cpus [Integer, nil] the CPU count; the machine's when nil
        def initialize(registry, load: nil, cpus: nil)
          @registry = registry
          @load = load || -> { self.class.uptime_load }
          @cpus = cpus || Etc.nprocessors
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

        # @return [Float] the load above which no session is started: the world's, else the CPU count
        def max_load = (declared(MAX_LOAD)[:limit] || @cpus).to_f

        # @return [Integer] the cap on started rows
        def cap = WorkLimits.cap(@registry)

        # @return [Hash{String => String}] the environment every dispatched session starts with
        def session_environment
          dir = declared(SESSION)[:cargo_target_dir]
          dir ? { "CARGO_TARGET_DIR" => File.expand_path(dir.to_s) } : {}
        end

        # @return [Integer, nil] the `nice` increment for a session's processes, nil for none
        def nice = declared(SESSION)[:nice]

        private

        def declared(verb) = @registry&.world("Tickets")&.for_verb(verb) || {}
      end
    end
  end
end
