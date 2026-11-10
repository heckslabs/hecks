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
    class BoundedCapture
      # The variable naming the file each example writes its file and description to.
      PROGRESS = "HECKS_SPEC_PROGRESS"

      # The Tickets world verb that carries the bounds.
      VERB = "spec_bounds"

      # The bounds, in seconds, when the world names none: the same numbers `tickets.world` sets.
      DEFAULTS = { file_seconds: 600, check_seconds: 2400 }.freeze

      # Seconds between asking the tree to end and ending it.
      GRACE = 5

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
          out, err, status, stopped = run(argv, env.merge(PROGRESS => progress), chdir)
          Result.new(out, stopped ? "#{err}#{stop_line(progress)}\n" : err, status, stopped)
        end
      rescue Errno::ENOENT => e
        Result.new("", e.message, 127, false)
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
          stopped = waiter.join(@seconds).nil?
          stop(waiter) if stopped
          [*readers.map { |reader| reader.join(GRACE)&.value.to_s }, waiter.value.exitstatus || 1, stopped]
        end
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

      def stop_line(progress)
        "stopped: ran past the #{@seconds}-second bound (#{@setting}) #{place(progress)}"
      end

      def place(progress)
        file, example = File.file?(progress.to_s) ? File.read(progress).split("\t", 2) : []
        file ? "in #{file}, example #{example.to_s.strip.inspect}" : "before any example started"
      end
    end
  end
end
