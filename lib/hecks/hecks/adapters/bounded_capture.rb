# frozen_string_literal: true

require "open3"
require "tmpdir"
require_relative "../../rust_build/session_build"

module Hecks
  module Adapters
    # A program run under a wall-clock bound. The program leads a process group of its own, so
    # when the bound passes the whole tree it started is ended (asked to stop, then killed after
    # `GRACE` seconds), and the answer says it was stopped and where: the spec file and example
    # the run was in, read from the progress file `spec/support/spec_progress.rb` writes before
    # every example. A run that carries `PROGRESS` already shares that file with the runs inside it,
    # so a bound around a launcher call names the example its innermost spec process was in.
    #
    # The directory the program runs in is watched as well: a program started in a directory that
    # is gone is refused by name, and one whose directory disappears while it runs (a temporary
    # clone removed under it) is ended with its tree, so a check never outlives its checkout.
    class BoundedCapture
      # The variable naming the file each example writes its file and description to.
      PROGRESS = "HECKS_SPEC_PROGRESS"

      # The Tickets world verb that carries the bounds.
      VERB = "spec_bounds"

      # The bounds, in seconds, when the world names none: the same numbers `tickets.world` sets.
      DEFAULTS = { file_seconds: 600, check_seconds: 2400, impacted_seconds: 600, impacted_workers: 4 }.freeze

      # Seconds between asking the tree to end and ending it.
      GRACE = 5

      # Seconds between looks at whether the directory the program runs in still exists.
      WATCH = 1

      # How a bounded run ended.
      #
      # @!attribute [r] out
      #   @return [String] what it wrote to stdout
      # @!attribute [r] err
      #   @return [String] what it wrote to stderr, and the stop line when the bound ended it
      # @!attribute [r] status
      #   @return [Integer] its exit status; 1 when a signal ended it
      # @!attribute [r] stopped
      #   @return [Boolean] whether the bound ended it
      Result = Struct.new(:out, :err, :status, :stopped) do
        # @return [Boolean] whether it ended by itself with status 0
        def ok? = status.zero? && !stopped
      end

      # @param root [String] a hecks checkout
      # @param key [Symbol] a key of `DEFAULTS`
      # @return [Integer] that bound as the checkout's Tickets world sets it, else its default
      def self.seconds(root, key)
        Integer(RustBuild::SessionBuild.world_row(root, VERB)[key] || DEFAULTS.fetch(key))
      end

      # @param seconds [Numeric] how long the program may run
      # @param setting [String] the setting the bound comes from, named in the stop line
      def initialize(seconds:, setting:)
        @seconds = seconds
        @setting = setting
      end

      # @param argv [Array<String>] the program and its arguments
      # @param env [Hash{String => String, nil}] variables to set for it; nil unsets one
      # @param chdir [String] the directory it runs in
      # @return [Result] how it ended; a program that is not installed is a `Result` with status
      #   127 and its reason in `err`, not a raise
      def call(argv, env: {}, chdir: Dir.pwd)
        with_progress(env) do |progress|
          out, err, status, reason = run(argv, env.merge(PROGRESS => progress), chdir)
          Result.new(out, reason ? "#{err}#{stop_line(reason, progress, chdir)}\n" : err, status, !reason.nil?)
        end
      rescue Errno::ENOENT => e
        Result.new("", refusal(e, chdir), 127, false)
      end

      private

      def with_progress(env, &)
        given = env.fetch(PROGRESS) { ENV.fetch(PROGRESS, nil) }
        return yield(given) unless given.to_s.empty?

        Dir.mktmpdir("spec-progress") { |dir| yield File.join(dir, "progress") }
      end

      def run(argv, env, chdir)
        Open3.popen3(env, *argv, chdir: chdir, pgroup: true) do |input, out, err, waiter|
          input.close
          readers = [out, err].map { |stream| Thread.new { stream.read } }
          reason = await(waiter, chdir)
          stop(waiter) if reason
          [*readers.map { |reader| reader.join(GRACE)&.value.to_s }, waiter.value.exitstatus || 1, reason]
        end
      end

      # @return [Symbol, nil] why the program must end: `:bound` when the time ran out, `:vanished`
      #   when its directory went away, or when the program ended non-zero with its directory gone;
      #   nil when it ended by itself
      def await(waiter, chdir)
        deadline = now + @seconds
        loop do
          return ended(waiter, chdir) if waiter.join((deadline - now).clamp(0, WATCH))
          return :bound if now >= deadline
          return :vanished unless File.directory?(chdir)
        end
      end

      # A program run with bundler preloaded dies of getcwd when its directory is removed, before
      # the next look, so a non-zero end with the directory gone is read as that death. The exit
      # status cannot tell it from the program's own failure, which counts as vanished too.
      #
      # @return [Symbol, nil] `:vanished` when the program failed and its directory is gone
      def ended(waiter, chdir)
        :vanished unless waiter.value.success? || File.directory?(chdir)
      end

      def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      def refusal(error, chdir)
        return error.message if File.directory?(chdir)

        "refused: #{chdir} is gone, and a program is not started in a vanished directory (#{error.message})"
      end

      def stop(waiter)
        signal("TERM", waiter.pid)
        signal("KILL", waiter.pid) unless waiter.join(GRACE)
      end

      def signal(name, group)
        Process.kill(name, -group)
      rescue Errno::ESRCH, Errno::EPERM
        nil
      end

      def stop_line(reason, progress, chdir)
        return "stopped: its directory #{chdir} is gone #{place(progress)}" if reason == :vanished

        "stopped: ran past the #{@seconds}-second bound (#{@setting}) #{place(progress)}"
      end

      def place(progress)
        file, example = File.file?(progress.to_s) ? File.read(progress).split("\t", 2) : []
        file ? "in #{file}, example #{example.to_s.strip.inspect}" : "before any example started"
      end
    end
  end
end
