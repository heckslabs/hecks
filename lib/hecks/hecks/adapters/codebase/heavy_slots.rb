# frozen_string_literal: true

require "fileutils"
require "hecks/cache_dir"
require "hecks/rust_build/build_lock"
require "hecks/rust_build/world_rows"

module Hecks
  module Adapters
    module Codebase
      # The machine's places for heavy jobs: a spec batch or a gate run takes one before it starts
      # and lets it go when it ends, so at most the Tickets world's `heavy_jobs` cap of them run at
      # once and the rest wait their turn, first come, first served.
      #
      # A place is a kernel `flock` on one of `cap` files under the cache directory, so a holder
      # that dies, even killed, frees its place at once and none is ever held for a dead process.
      # The job's own time bounds start inside the block, so waiting never counts toward them.
      # Nothing running is stopped or paused: a place only decides when a job starts.
      #
      # A job does not wait with `HECKS_NO_HEAVY_SLOT=1`, in CI, or when a parent that holds a
      # place started it (`HELD`, set for the children of a holder), which would wait for itself.
      class HeavySlots
        # The Tickets world verb that carries the cap.
        VERB = "heavy_jobs"

        # The cap when the world names none: the number `tickets.world` sets.
        DEFAULT_CAP = 3

        # The environment variable a holder sets for the children it starts.
        HELD = "HECKS_HEAVY_SLOT_HELD"

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
          report, note = new(cap: cap_of(root)).hold(job, &)
          note.empty? ? report : "#{note}\n#{report}"
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
        # @param timing [Hash] `clock:` answers the time in seconds and `pause:` sleeps the given
        #   seconds; the monotonic clock and `sleep` when absent
        def initialize(cap:, dir: self.class.directory, base: ENV, err: $stderr, **timing)
          @cap = cap
          @dir = dir
          @base = base
          @err = err
          @clock = timing.fetch(:clock) { -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) } }
          @pause = timing.fetch(:pause) { ->(seconds) { sleep(seconds) } }
        end

        # Runs the block in a place, waiting for one when every place is taken.
        #
        # @param job [String] the job's class (`gate`, `spec_batch`), written into the place
        # @return [Array(Object, String)] what the block returned, and the wait to name in the
        #   run's report: empty when it took a place at once
        def hold(job, &)
          return [yield, ""] if bypass?

          place, note = acquire(job)
          return [yield, note] unless place

          begin
            [holding(place, job, &), note]
          ensure
            place.close
          end
        end

        private

        def bypass?
          @base["HECKS_NO_HEAVY_SLOT"] == "1" || !@base[HELD].to_s.empty? || !@base["CI"].to_s.empty?
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
          before = ENV.fetch(HELD, nil)
          ENV[HELD] = Process.pid.to_s
          yield
        ensure
          ENV[HELD] = before
        end

        def waited(started)
          seconds = (@clock.call - started).round
          seconds.positive? ? "waited #{seconds} s for a heavy-job slot (#{@cap} of #{@cap} taken)" : ""
        end

        # Says once that the job waits, and for whom.
        def say_waiting(job)
          return if @noted

          @noted = true
          @err.puts("hecks: #{job} waiting for a heavy-job slot, #{@cap} of #{@cap} taken (#{holders.join(", ")})")
        end

        def gave_up(job)
          note = "no longer waiting for a heavy-job slot after #{GIVE_UP_AFTER} s; #{job} runs anyway"
          @err.puts("hecks: #{note}")
          note
        end

        # @return [Array<String>] what each place's file names: the job's class and its pid
        def holders
          (0...@cap).map { |index| File.read(File.join(@dir, "slot-#{index}.lock")).strip }.reject(&:empty?)
        rescue SystemCallError
          []
        end
      end
    end
  end
end
