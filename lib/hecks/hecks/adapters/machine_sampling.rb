# frozen_string_literal: true

require "time"
require_relative "console_capture"
require_relative "machine_sampling/marks"
require_relative "machine_sampling/states"
require_relative "machine_sampling/readings"
require_relative "machine_sampling/history"
require_relative "machine_sampling/process_classes"
require_relative "machine_sampling/cap_bounds"
require_relative "dispatching/meter_switch"

module Hecks
  module Adapters
    # The `Sampling` port's adapter for `Machine`: it reads the machine's gauges, judges them
    # against the Tickets world's marks and answers each gauge's state and the state it stood in
    # before. The bluebook says what a crossing is; this reads the machine, which the bluebook
    # never does. A reading within `interval` seconds of the last is refused, so the heartbeat's
    # beats take at most one reading a minute. Each reading keeps Roundhouse's metered load beside
    # its own (ADR 0222, phase 3, metering); with the Tickets world's `metering.roundhouse` switch
    # on, the metered load is the load it judges and records, and `source` says which it is.
    class MachineSampling
      # The seconds on a clock that only moves forward, for the interval between two readings.
      MONOTONIC = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }

      # When a reading is taken, on the wall clock in ISO-8601 UTC, so stamps sort as times do.
      WALL = -> { Time.now.utc.iso8601 }

      @last = nil

      class << self
        # @return [Float, nil] when the last reading was taken, on the clock the adapter was given
        attr_accessor :last
      end

      # @param registry [Runtime::Registry, nil] the booted registry whose world is read
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] stand-ins: `readings:` answers the gauges, `clock:` answers seconds,
      #   `processes:` answers the process classes ({ProcessClasses} when absent), `meter:` answers
      #   Roundhouse's load (none beside stand-in `readings:`, the live meter otherwise), `stamp:`
      #   answers when a reading is taken (ISO-8601 UTC from the wall clock when absent)
      # @param root [String, nil] unused
      def initialize(registry: nil, aggregate: nil, settings: {}, root: nil)
        @registry = registry
        @readings = settings[:readings] || -> { Readings.new.call }
        @clock = settings.fetch(:clock, MONOTONIC)
        @stamp = settings.fetch(:stamp, WALL)
        @processes = settings[:processes] || ProcessClasses.new
        @meter = settings.fetch(:meter) { settings.key?(:readings) ? -> {} : -> { Dispatching::MeterSwitch.load } }
      end

      # The `Busiest` query: which process classes use the CPU and whose child they are. Read-only.
      #
      # @return [Array<Hash>] `name`, `count`, `cpu` and `session` per class, busiest first
      def busiest(**) = @processes.rows

      # @param held [Hash] the `Machine` record
      # @return [Hash{Symbol => Object}] the gauges, the states they leave and stood in before, the
      #   owner's bounds on the moving work cap ({CapBounds}) and `taken_at`, when it was taken
      # @raise [ConsoleCapture::Failure] when the last reading is less than `interval` seconds old
      def read(**held)
        marks = Marks.of(@registry)
        refuse_a_repeat(marks[:interval], held)
        gauges = metered(@readings.call)
        states = States.new(judged(gauges), marks, History.new(@registry).states).to_h
        gauges.merge(states, CapBounds.of(@registry), taken_at: @stamp.call)
      end

      private

      # The gauges the states are judged on: with Roundhouse's load as the one recorded, the load
      # alone decides the load state, rise and fall alike, so the CPU's idle share cannot hold a
      # load that has fallen under its low mark above it.
      def judged(gauges) = gauges[:source] == "roundhouse" ? gauges.merge(cpu_idle: nil) : gauges

      # The gauges with Roundhouse's load beside the sampler's, and, with the switch on and a
      # metered load read, the metered load as the one judged and recorded.
      def metered(gauges)
        load = @meter.call
        counted = load && Dispatching::MeterSwitch.on?(@registry)
        gauges.merge(metered_load: load, source: counted ? "roundhouse" : "uptime", **(counted ? { load: load } : {}))
      end

      def refuse_a_repeat(interval, _held)
        now = @clock.call
        last = self.class.last
        raise ConsoleCapture::Failure, "read #{(now - last).round} seconds ago" if last && now - last < interval

        self.class.last = now
      end
    end
  end
end
