# frozen_string_literal: true

require "monitor"
require "stringio"

module Hecks
  module Adapters
    # Runs a command-line entry point that prints and exits, and hands back what it said and how
    # it ended, so an adapter can reuse `Hecks::CLI::*` unchanged.
    #
    # It is the shared base for every Custodian adapter that wraps an existing CLI: the entry
    # point keeps its own printing, `exit` and `abort`, and the adapter turns the outcome into a
    # port answer (the text) or a refusal (`Failed`). `$stdout`, `$stderr`, `ENV` and the working
    # directory are process-wide, so every capture, and every `RustBuild` call, holds the one
    # `LOCK` for its length: two captures never interleave, and one may nest inside another on
    # the same thread.
    module ConsoleCapture
      # What an entry point said and how it ended.
      #
      # @!attribute [r] output
      #   @return [String] everything printed to stdout and stderr, in order
      # @!attribute [r] status
      #   @return [Integer] the exit status; 0 when the entry point returned normally
      Outcome = Struct.new(:output, :status) do
        # @return [Boolean] whether the entry point ended with status 0
        def ok? = status.zero?
      end

      # Raised when a captured entry point ends with a non-zero status; the message is its output.
      class Failure < StandardError; end

      # The process-wide lock a capture holds; reentrant, so a capture may run another.
      LOCK = Monitor.new

      module_function

      # Runs the block holding the process-wide capture lock.
      #
      # @yield the work that swaps a process-wide stream, variable or directory
      # @return [Object] the block's value
      def synchronize(&) = LOCK.synchronize(&)

      # Runs the block with stdout and stderr captured.
      #
      # @yield the entry point to run
      # @return [Outcome] the text printed and the exit status
      def capture(&)
        synchronize { redirected(&) }
      end

      # Runs the block with both streams pointed at one buffer, putting them back afterwards.
      def redirected(&)
        saved  = [$stdout, $stderr]
        buffer = StringIO.new
        $stdout = $stderr = buffer
        status = exit_status(&)
        Outcome.new(buffer.string, status)
      ensure
        $stdout, $stderr = saved
      end

      # The status the block ends with: 0, or the one an `exit` inside it carries.
      def exit_status
        yield
        0
      rescue SystemExit => e
        e.status
      end

      # Runs the block captured and answers its text, or refuses with it.
      #
      # @yield the entry point to run
      # @return [String] the output when the entry point ended with status 0
      # @raise [Failure] when it ended otherwise; the message is what it printed
      def answer(&)
        outcome = capture(&)
        raise Failure, outcome.output.strip unless outcome.ok?

        outcome.output
      end
    end
  end
end
