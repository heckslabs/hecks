# frozen_string_literal: true

require_relative "console_capture"
require_relative "machine_sampling/marks"
require_relative "machine_sampling/states"
require_relative "machine_sampling/readings"
require_relative "machine_sampling/history"
require_relative "machine_sampling/process_classes"

module Hecks
  module Adapters
    # The `Sampling` port's adapter for `Machine`: it reads the machine's gauges, judges them
    # against the Tickets world's marks and answers each gauge's state and the state it stood in
    # before. The bluebook says what a crossing is; this reads the machine, which the bluebook
    # never does. A reading within `interval` seconds of the last is refused, so the heartbeat's
    # beats take at most one reading a minute.
    class MachineSampling
      # The seconds on a clock that only moves forward, for the interval between two readings.
      MONOTONIC = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }

      @last = nil

      class << self
        # @return [Float, nil] when the last reading was taken, on the clock the adapter was given
        attr_accessor :last
      end

      # @param registry [Runtime::Registry, nil] the booted registry whose world is read
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] stand-ins: `readings:` answers the gauges, `clock:` answers seconds,
      #   `processes:` answers the process classes ({ProcessClasses} when absent)
      # @param root [String, nil] unused
      def initialize(registry: nil, aggregate: nil, settings: {}, root: nil)
        @registry = registry
        @readings = settings[:readings] || -> { Readings.new.call }
        @clock = settings[:clock] || MONOTONIC
        @processes = settings[:processes] || ProcessClasses.new
      end

      # The `Busiest` query: which process classes use the CPU and whose child they are. Read-only.
      #
      # @return [Array<Hash>] `name`, `count`, `cpu` and `session` per class, busiest first
      def busiest(**) = @processes.rows

      # @param held [Hash] the `Machine` record
      # @return [Hash{Symbol => Object}] the gauges, and the states they leave and stood in before
      # @raise [ConsoleCapture::Failure] when the last reading is less than `interval` seconds old
      def read(**held)
        marks = Marks.of(@registry)
        refuse_a_repeat(marks[:interval], held)
        gauges = @readings.call
        gauges.merge(States.new(gauges, marks, History.new(@registry).states).to_h)
      end

      private

      def refuse_a_repeat(interval, _held)
        now = @clock.call
        last = self.class.last
        raise ConsoleCapture::Failure, "read #{(now - last).round} seconds ago" if last && now - last < interval

        self.class.last = now
      end
    end
  end
end
