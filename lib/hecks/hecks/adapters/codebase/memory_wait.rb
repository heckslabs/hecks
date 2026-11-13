# frozen_string_literal: true

require "hecks/rust_build/build_lock"
require "hecks/rust_build/world_rows"
require_relative "../machine_sampling/marks"
require_relative "../machine_sampling/readings"
require_relative "../machine_sampling/states"

module Hecks
  module Adapters
    module Codebase
      # A heavy job's wait for memory before it takes a place: while the machine's memory is low by
      # the Machine's own marks (`machine_marks` in the Tickets world, judged by
      # {MachineSampling::States}) the job does not start, and it starts once memory has recovered.
      #
      # It reads the machine through the Sampling port's reader every `memory_poll_seconds` of the
      # world's `heavy_jobs` line, and holds no place while it waits, so a job held for memory
      # blocks no other. After {GIVE_UP_AFTER} seconds it gives up and the job runs, saying so on
      # stderr and at the top of the job's report.
      class MemoryWait
        # The Tickets world verb whose line carries the poll interval.
        VERB = "heavy_jobs"

        # Seconds between two readings when the world names none: `top` takes about a second.
        POLL_SECONDS = 10.0

        # Seconds a job waits for memory before it runs anyway: the heavy-job place's figure.
        GIVE_UP_AFTER = RustBuild::BuildLock::GIVE_UP_AFTER

        # @param root [String] a hecks checkout
        # @return [Float] the seconds between readings its Tickets world sets, else `POLL_SECONDS`
        def self.poll_of(root) = Float(RustBuild::WorldRows.row(root, VERB)[:memory_poll_seconds] || POLL_SECONDS)

        # @param root [String] the hecks checkout whose world sets the marks and the interval
        # @return [MemoryWait] the wait that reads this machine
        def self.of(root)
          declared = RustBuild::WorldRows.row(root, MachineSampling::Marks::VERB)
          new(marks: MachineSampling::Marks.laid_over(declared), poll: poll_of(root))
        end

        # @param marks [Hash{Symbol => Float}] see {MachineSampling::Marks}
        # @param poll [Float] seconds between two readings
        # @param readings [#call] answers the machine's readings; the Sampling port's reader when
        #   absent
        # @param err [#puts] where the waiting note goes
        # @param timing [Hash] `clock:` answers the time in seconds and `pause:` sleeps the given
        #   seconds; the monotonic clock and `sleep` when absent
        def initialize(marks:, poll:, readings: MachineSampling::Readings.new, err: $stderr, **timing)
          @marks = marks
          @poll = poll
          @readings = readings
          @err = err
          @clock = timing.fetch(:clock) { -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) } }
          @pause = timing.fetch(:pause) { ->(seconds) { sleep(seconds) } }
        end

        # Waits while memory is low.
        #
        # @param job [String] the job's class (`gate`, `spec_batch`)
        # @return [String] the wait to name in the run's report: empty when memory was not low
        def wait(job)
          started = @clock.call
          loop do
            return waited(started) unless low?
            return gave_up(job) if @clock.call - started >= GIVE_UP_AFTER

            say_waiting(job)
            @pause.call(@poll)
          end
        end

        private

        # Whether memory is low now, judged from the state the last look left, so a reading in the
        # gap between the marks keeps a wait going until memory has recovered.
        def low?
          before = @state ? { memory: @state } : {}
          @state = MachineSampling::States.new(@readings.call, @marks, before).to_h[:memory_state]
          @state == "low"
        end

        def waited(started)
          seconds = (@clock.call - started).round
          seconds.positive? ? "waited #{seconds} s while memory was low (the Machine's MemoryLow marks)" : ""
        end

        def say_waiting(job)
          return if @noted

          @noted = true
          @err.puts("hecks: #{job} waiting: memory low (swap over #{@marks[:swap_low]}% or compressor over " \
                    "#{@marks[:compressor_gb]} GB)")
        end

        def gave_up(job)
          note = "memory stayed low for #{GIVE_UP_AFTER} s; #{job} runs anyway"
          @err.puts("hecks: #{note}")
          note
        end
      end
    end
  end
end
