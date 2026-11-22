# frozen_string_literal: true

require_relative "accept_watch"
require_relative "descriptor_limit"
require_relative "full_log"

module Hecks
  module Adapters
    module PipelineBoard
      # The thread that takes connections from the server's listener and hands each socket to the
      # block it was given, on a thread of its own. It beats for an AcceptWatch on every pass, idle
      # or not, so a pass that does not come is a stall the watch logs.
      class AcceptLoop
        # Seconds the loop waits for a connection before it beats and waits again.
        TICK = 1

        # Seconds the loop waits after accept finds the descriptor table full.
        FULL_PAUSE = 0.1

        # @param listener [TCPServer] where connections arrive
        # @param pause [Numeric] seconds to wait when the descriptor table is full
        # @param clock [#call] answers a monotonic time in seconds
        # @param log [#call] takes one message
        # @param limit [#raise!] raises the descriptor limit when the loop starts
        # @yield [socket] serves one accepted connection
        def initialize(listener, pause: FULL_PAUSE, clock: AcceptWatch::MONOTONIC,
                       log: AcceptWatch::STDERR_LOG, limit: DescriptorLimit, &serve)
          @limit = limit
          @log = log
          @listener = listener
          @serve = serve
          @pause = pause
          @full = FullLog.new(clock: clock, log: log)
          @watch = AcceptWatch.new(target: -> { @thread })
        end

        # Raises the descriptor limit, then starts the loop and its watch on background threads.
        # @return [AcceptLoop] self
        def start
          @limit.raise!(log: @log)
          @thread = Thread.new { run }
          @watch.start
          self
        end

        # Blocks until the loop ends, which is when the listener is closed.
        # @return [void]
        def join = @thread&.join

        # Ends the watch; the loop ends when its listener is closed.
        # @return [void]
        def stop = @watch.stop

        private

        def run
          loop do
            @watch.beat
            next unless @listener.wait_readable(TICK)

            accept_one
          end
        rescue IOError, Errno::EBADF
          nil
        end

        def accept_one
          socket = @listener.accept_nonblock(exception: false)
          Thread.new(socket) { |accepted| @serve.call(accepted) } unless socket == :wait_readable
        rescue Errno::EMFILE, Errno::ENFILE => e
          @full.say(e)
          sleep(@pause)
        end
      end
    end
  end
end
