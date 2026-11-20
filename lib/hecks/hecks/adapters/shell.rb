# frozen_string_literal: true

require "open3"

module Hecks
  module Adapters
    # The `Shell` port's adapter: runs one program with its arguments and hands back what it said.
    #
    # It is the single place a Custodian adapter starts a subprocess through, so `Git` builds on it
    # rather than calling `Open3` itself. The command is an argument list, never a string for a
    # shell to split, so nothing a caller passes is interpreted.
    class Shell
      # What a program said and how it ended. Each stream is labelled UTF-8 whatever the caller's
      # locale, so a launchd job without one reads the same text a terminal does. A stream that is
      # not valid UTF-8 (a binary file `git show` printed) keeps its exact bytes as `BINARY`
      # instead: joining it to UTF-8 text that is not ASCII raises `Encoding::CompatibilityError`.
      #
      # @!attribute [r] out
      #   @return [String] what it wrote to stdout, UTF-8 when valid and binary otherwise
      # @!attribute [r] err
      #   @return [String] what it wrote to stderr, UTF-8 when valid and binary otherwise
      # @!attribute [r] status
      #   @return [Process::Status] how it ended
      Result = Struct.new(:out, :err, :status) do
        # @return [Boolean] whether the program ended with status 0
        def ok? = status.success?

        # @return [Integer, nil] the status the program ended with, or nil when a signal ended it
        def exit_code = status.exitstatus
      end

      # Accepts the arguments every driven adapter is built with and keeps none of them.
      #
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] unused
      # @param root [String, nil] unused
      def initialize(aggregate: nil, settings: {}, root: nil); end

      # Seconds a stopped program, then each reader, gets to finish before the next step.
      GRACE_SECONDS = 2

      # Runs a program and waits for it. A caller that is killed or interrupted while it waits
      # stops the program (`TERM`, then `KILL`) and lets the readers drain before the pipes
      # close, so no reader thread dies on a stream closed under it; a program that ends by
      # itself is never signalled.
      #
      # @param command [Array<String>] the program, then its arguments
      # @param env [Hash{String => String, nil}] variables to set for it; nil unsets one
      # @param chdir [String, nil] the directory to run it in
      # @return [Result] its output and status; a program that is not installed is a `Result` with
      #   status 127 and its reason in `err`, not a raise
      def capture(*command, env: {}, chdir: nil)
        options = chdir ? { chdir: chdir } : {}
        Thread.handle_interrupt(Object => :never) do
          Open3.popen3(env, *command, **options) { |stdin, out, err, waiter| run(stdin, out, err, waiter) }
        end
      rescue Errno::ENOENT => e
        Result.new("", e.message, Struct.new(:success?, :exitstatus).new(false, 127))
      end

      private

      # Interrupts are taken only while the program is read; the cleanup runs whatever ended it.
      def run(stdin, out, err, waiter)
        readers = nil
        Thread.handle_interrupt(Object => :immediate) do
          stdin.close
          readers = [out, err].map { |io| Thread.new { text(io) }.tap { |thread| thread.report_on_exception = false } }
          Result.new(*readers.map(&:value), waiter.value)
        end
      ensure
        settle(waiter, readers)
      end

      # The stream's bytes, read without transcoding, as UTF-8 when they are valid UTF-8.
      def text(io)
        io.binmode
        read = io.read.force_encoding(Encoding::UTF_8)
        read.valid_encoding? ? read : read.force_encoding(Encoding::BINARY)
      end

      def settle(waiter, readers)
        stop(waiter) if waiter.alive?
        waiter.join
        Array(readers).each { |thread| thread.join(GRACE_SECONDS) || thread.kill }
      end

      def stop(waiter)
        signal("TERM", waiter.pid)
        signal("KILL", waiter.pid) unless waiter.join(GRACE_SECONDS)
      end

      def signal(name, pid)
        Process.kill(name, pid)
      rescue Errno::ESRCH, Errno::EPERM
        nil
      end
    end
  end
end
