# frozen_string_literal: true

require "fileutils"
require_relative "build_policy"

module Hecks
  module RustBuild
    # One Rust build at a time on the machine.
    #
    # Every `cargo` hecks starts runs while holding a lock on one file under the cache directory,
    # so several agents building at once queue instead of each taking every core. The lock is the
    # kernel's `flock`: it is released when the holder exits, even if it is killed, so a dead
    # holder never blocks the next build. A build started by hand, outside hecks, is not held.
    #
    # The lock is not taken when `HECKS_NO_BUILD_LOCK=1`, in CI (`CI` is set), or when a parent
    # that already holds it started this one (`HECKS_BUILD_LOCK_HELD`), which would otherwise wait
    # for itself.
    module BuildLock
      # The environment variable a holder passes to the child it starts.
      HELD = "HECKS_BUILD_LOCK_HELD"

      # Seconds a build waits before it says whom it waits for.
      NOTE_AFTER = 5

      # Seconds after which a build stops waiting and runs anyway, with a note.
      GIVE_UP_AFTER = 1800

      # How often a waiting build looks at the lock again.
      POLL = 0.25

      module_function

      # Runs the block while holding the lock.
      #
      # @param base [#[]] the environment, for the switches above
      # @param err [#puts] where the waiting notes go
      # @param file [String] the lock file
      # @param clock [#call] answers the time in seconds
      # @param pause [#call] sleeps the given seconds
      # @yieldparam held [Hash{String => String}] the variable to add to the child's environment
      #   so a build it starts does not wait for the lock its parent holds; empty when not held
      # @return [Object] what the block returned
      def hold(base: ENV, err: $stderr, file: path, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) },
               pause: ->(seconds) { sleep(seconds) }, &)
        return yield({}) if bypass?(base)
        return yield(HELD => Process.pid.to_s) if Thread.current[HELD]

        handle = open_lock(file)
        return yield({}) unless handle

        begin
          acquire(handle, err, clock, pause)
          held(handle, &)
        ensure
          handle.close
        end
      end

      # Records the holder in the file and runs the block, marking this thread as the holder so a
      # build it starts itself does not wait for its own lock.
      def held(handle)
        handle.truncate(0)
        handle.write(Process.pid.to_s)
        handle.flush
        Thread.current[HELD] = true
        yield(HELD => Process.pid.to_s)
      ensure
        Thread.current[HELD] = nil
      end

      # Holds the lock for a command that compiles (`cargo` or `rustc`, directly or under
      # `rustup run`), and runs any other command without it.
      #
      # @param command [Array<String>] the program and its arguments
      # @yieldparam held [Hash{String => String}] see `hold`
      # @return [Object] what the block returned
      def building(command, &)
        compiles?(command) ? hold(&) : yield({})
      end

      # @param command [Array<String>] the program and its arguments
      # @return [Boolean] whether it compiles Rust
      def compiles?(command) = command.any? { |word| %w[cargo rustc].include?(File.basename(word.to_s)) }

      # @param base [#[]] the environment
      # @return [Boolean] whether this build skips the lock
      def bypass?(base)
        base["HECKS_NO_BUILD_LOCK"] == "1" || !base[HELD].to_s.empty? || !base["CI"].to_s.empty?
      end

      # @return [String] the lock file, under the cache directory
      def path = File.join(BuildPolicy.cache_root, "build.lock")

      # @return [File, nil] the opened lock file, nil when the cache directory cannot be written
      #   to: a build never fails for want of its lock
      def open_lock(file)
        FileUtils.mkdir_p(File.dirname(file))
        File.open(file, File::CREAT | File::RDWR, 0o600)
      rescue SystemCallError
        nil
      end

      # Waits for the lock, saying once whom it waits for and giving up after `GIVE_UP_AFTER`.
      def acquire(handle, err, clock, pause)
        started = clock.call
        noted = false
        until handle.flock(File::LOCK_EX | File::LOCK_NB)
          waited = clock.call - started
          return err.puts("hecks: no longer waiting for another Rust build; building anyway") if waited >= GIVE_UP_AFTER

          noted ||= say_waiting(handle, err) if waited >= NOTE_AFTER
          pause.call(POLL)
        end
      end

      # @return [Boolean] true, once the note is out
      def say_waiting(handle, err)
        holder = File.read(handle.path).to_s.strip
        err.puts("hecks: waiting for another Rust build#{" (pid #{holder})" unless holder.empty?} to finish")
        true
      rescue SystemCallError
        true
      end
    end
  end
end
