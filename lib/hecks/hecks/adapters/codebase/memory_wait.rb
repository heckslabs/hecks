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
      # blocks no other. After the world's `memory_give_up_seconds` (else {GIVE_UP_AFTER}) it gives
      # up and the job runs, saying so on stderr and at the top of the job's report; either way the
      # note carries the reading that held it.
      class MemoryWait
        # The Tickets world verb whose line carries the poll interval.
        VERB = "heavy_jobs"

        # Seconds between two readings when the world names none: `top` takes about a second.
        POLL_SECONDS = 10.0

        # Seconds a job waits for memory before it runs anyway when the world names none: memory
        # is a hint, not a place, so it is far shorter than the place's wait.
        GIVE_UP_AFTER = 120.0

        # @param root [String] a hecks checkout
        # @return [Float] the seconds between readings its Tickets world sets, else `POLL_SECONDS`
        def self.poll_of(root) = Float(RustBuild::WorldRows.row(root, VERB)[:memory_poll_seconds] || POLL_SECONDS)

        # @param root [String] a hecks checkout
        # @return [Float] the seconds a memory wait lasts its Tickets world sets, else `GIVE_UP_AFTER`
        def self.give_up_of(root) = Float(RustBuild::WorldRows.row(root, VERB)[:memory_give_up_seconds] || GIVE_UP_AFTER)

        # @param root [String] the hecks checkout whose world sets the marks and the interval
        # @return [MemoryWait] the wait that reads this machine
        def self.of(root)
          declared = RustBuild::WorldRows.row(root, MachineSampling::Marks::VERB)
          new(marks: MachineSampling::Marks.laid_over(declared), poll: poll_of(root), give_up: give_up_of(root))
        end

        # @param marks [Hash{Symbol => Float}] see {MachineSampling::Marks}
        # @param poll [Float] seconds between two readings
        # @param readings [#call] answers the machine's readings; the Sampling port's reader when
        #   absent
        # @param err [#puts] where the waiting note goes
        # @param timing [Hash] `give_up:` is the seconds to wait before the job runs anyway,
        #   `GIVE_UP_AFTER` when absent; `clock:` answers the time in seconds and `pause:` sleeps the given
        #   seconds; the monotonic clock and `sleep` when absent
        def initialize(marks:, poll:, readings: MachineSampling::Readings.new, err: $stderr, **timing)
          @marks = marks
          @poll = poll
          @readings = readings
          @err = err
          @give_up = timing.fetch(:give_up, GIVE_UP_AFTER)
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
            return gave_up(job) if @clock.call - started >= @give_up

            say_waiting(job)
            @pause.call(@poll)
          end
        end

        private

        # Whether memory is low now, judged from the state the last look left, so a reading in the
        # gap between the marks keeps a wait going until memory has recovered.
        def low?
          before = @state ? { memory: @state } : {}
          reading = @readings.call
          @state = MachineSampling::States.new(reading, @marks, before).to_h[:memory_state]
          @held = reading if @state == "low"
          @state == "low"
        end

        def waited(started)
          seconds = (@clock.call - started).round
          seconds.positive? ? "waited #{seconds} s while memory was low (#{held_by})" : ""
        end

        # The reading that held the job, against the marks it was judged by.
        def held_by
          r = @held || {}
          "swap #{r[:swap_used_mb]&.round} MB over #{@marks[:swap_used_mb].round}, " \
            "compressor #{r[:compressor_gb].to_f} GB over #{@marks[:compressor_gb]}, " \
            "free #{r[:free_gb]} GB under #{@marks[:free_gb_low]}"
        end

        def say_waiting(job)
          return if @noted

          @noted = true
          @err.puts("hecks: #{job} waiting: memory low (#{held_by})")
        end

        def gave_up(job)
          note = "memory stayed low for #{@give_up.round} s (#{held_by}); #{job} runs anyway"
          @err.puts("hecks: #{note}")
          note
        end
      end
    end
  end
end
