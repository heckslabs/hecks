# frozen_string_literal: true

require "fileutils"
require "hecks/cache_dir"
require "hecks/rust_build/build_lock"
require "hecks/rust_build/world_rows"
require_relative "memory_wait"
require_relative "slot_text"
require_relative "spec_workers"

module Hecks
  module Adapters
    module Codebase
      # The machine's places for heavy jobs: a spec batch, a gate run or a landing's shallow check
      # takes one before it starts and lets it go when it ends, so at most the Tickets world's
      # `heavy_jobs` cap of them run at once and the rest wait their turn, first come, first served.
      #
      # A place is a kernel `flock` on one of `cap` files under the cache directory, so a holder
      # that dies, even killed, frees its place at once and none is ever held for a dead process.
      # Waiting never counts toward a job's own time bounds, and nothing running is stopped. A job
      # waits while memory is low first ({MemoryWait}); while it holds a place, its children's
      # workers are held to the world's `spec_workers` (`PARALLEL_PROCESSOR_COUNT`, which RuboCop
      # reads, unless already set). A job does not wait in CI or when a parent holding a place
      # started it (`HELD`); no switch skips the places.
      class HeavySlots
        # The Tickets world verb that carries the cap.
        VERB = "heavy_jobs"

        # The cap when the world names none: the number `tickets.world` sets.
        DEFAULT_CAP = 3

        # The environment variable a holder sets for the children it starts.
        HELD = "HECKS_HEAVY_SLOT_HELD"

        # The environment variable the parallel gem reads for its worker count.
        WORKERS = "PARALLEL_PROCESSOR_COUNT"

        # Seconds a job waits before it gives up and runs anyway: the Rust build lock's figure, so
        # a job never waits longer for a place than a build waits for its lock.
        GIVE_UP_AFTER = RustBuild::BuildLock::GIVE_UP_AFTER

        # How often a waiting job looks at the places again.
        POLL = 0.5

        # @param root [String] a hecks checkout
        # @return [Integer] the cap its Tickets world's `heavy_jobs` line sets, else `DEFAULT_CAP`
        def self.cap_of(root) = Integer(RustBuild::WorldRows.row(root, VERB)[:cap] || DEFAULT_CAP)

        # Runs a job of a checkout in a place and names any wait at the top of its report.
        #
        # @param root [String] the hecks checkout whose world sets the cap
        # @param job [String] the job's class
        # @yieldreturn [String] the job's report
        # @return [String] the report, after the line that names the wait when there was one
        def self.admitted(root, job, &)
          report, note = held(root, job, &)
          note.empty? ? report : "#{note}\n#{report}"
        end

        # Runs a job of a checkout in a place, for a job whose answer is not a report.
        #
        # @param root [String] the hecks checkout whose world sets the cap
        # @param job [String] the job's class
        # @return [Array(Object, String)] what the block returned, and the wait to name: empty when
        #   it took a place at once
        def self.held(root, job, &)
          new(cap: cap_of(root), memory: MemoryWait.of(root), workers: SpecWorkers.count(root)).hold(job, &)
        end

        # @param base [#[]] the environment
        # @return [String] the directory the places live in, under `HECKS_CACHE_DIR` when named
        def self.directory(base = ENV)
          named = base["HECKS_CACHE_DIR"].to_s
          named.empty? ? Hecks::CacheDir.path("heavy-jobs") : File.join(named, "heavy-jobs")
        end

        # @param cap [Integer] how many heavy jobs may run at once
        # @param dir [String] the directory the places live in
        # @param base [#[]] the environment, for the switches above
        # @param err [#puts] where the waiting note goes
        # @param options [Hash] `clock:` answers the time in seconds and `pause:` sleeps the given
        #   seconds, the monotonic clock and `sleep` when absent; `memory:` ({MemoryWait}) is waited
        #   on before a place is taken, none when absent; `workers:` is the worker count the held
        #   job's children are held to, none when absent
        def initialize(cap:, dir: self.class.directory, base: ENV, err: $stderr, **options)
          @cap = cap
          @dir = dir
          @base = base
          @err = err
          @memory, @workers = options.values_at(:memory, :workers)
          @clock = options.fetch(:clock) { -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) } }
          @pause = options.fetch(:pause) { ->(seconds) { sleep(seconds) } }
        end

        # Runs the block in a place, waiting for one when every place is taken.
        #
        # @param job [String] the job's class (`gate`, `spec_batch`), written into the place
        # @return [Array(Object, String)] what the block returned, and the wait to name in the
        #   run's report: empty when it took a place at once
        def hold(job, &)
          return [yield, ""] if bypass?

          memory = @memory ? @memory.wait(job) : ""
          place, slot = acquire(job)
          note = [memory, slot].reject(&:empty?).join("; ")
          return [yield, note] unless place

          begin
            [holding(place, job, &), note]
          ensure
            SlotText.release(place)
          end
        end

        private

        def bypass?
          !@base[HELD].to_s.empty? || !@base["CI"].to_s.empty?
        end

        # @return [Array(File, String), Array(nil, String)] the place taken and the wait's note;
        #   no place when the places cannot be opened or the wait gave up
        def acquire(job)
          started = @clock.call
          loop do
            place = free_place
            return [place, waited(started)] if place || unusable?

            return [nil, gave_up(job)] if @clock.call - started >= GIVE_UP_AFTER

            say_waiting(job)
            @pause.call(POLL)
          end
        end

        def free_place
          (0...@cap).each do |index|
            file = open_place(index)
            return file if file&.flock(File::LOCK_EX | File::LOCK_NB)

            file&.close
          end
          nil
        end

        def open_place(index)
          FileUtils.mkdir_p(@dir)
          File.new(File.join(@dir, "slot-#{index}.lock"), File::CREAT | File::RDWR, 0o600)
        rescue SystemCallError
          @unusable = true
          nil
        end

        def unusable? = @unusable == true

        def holding(place, job, &)
          place.truncate(0)
          place.write("#{job} #{Process.pid}")
          place.flush
          with_held(&)
        end

        def with_held
          before = ENV.values_at(HELD, WORKERS)
          ENV[HELD] = Process.pid.to_s
          ENV[WORKERS] ||= @workers.to_s if @workers
          yield
        ensure
          ENV[HELD], ENV[WORKERS] = before
        end

        def waited(started)
          seconds = (@clock.call - started).round
          seconds.positive? ? "waited #{seconds} s for a heavy-job slot (#{@cap} of #{@cap} taken)" : ""
        end

        # Says once that the job waits, and for whom.
        def say_waiting(job)
          return if @noted

          @noted = true
          held = SlotText.holders(@dir, @cap).join(", ")
          @err.puts("hecks: #{job} waiting for a heavy-job slot, #{@cap} of #{@cap} taken (#{held})")
        end

        def gave_up(job)
          note = "no longer waiting for a heavy-job slot after #{GIVE_UP_AFTER} s; #{job} runs anyway"
          @err.puts("hecks: #{note}")
          note
        end
      end
    end
  end
end
