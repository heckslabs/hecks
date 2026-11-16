# frozen_string_literal: true

require_relative "accept_watch"

module Hecks
  module Adapters
    module PipelineBoard
      # The thread that takes connections from the server's listener and hands each socket to the
      # block it was given, on a thread of its own. It beats for an AcceptWatch on every pass, idle
      # or not, so a pass that does not come is a stall the watch logs.
      class AcceptLoop
        # Seconds the loop waits for a connection before it beats and waits again.
        TICK = 1

        # @param listener [TCPServer] where connections arrive
        # @yield [socket] serves one accepted connection
        def initialize(listener, &serve)
          @listener = listener
          @serve = serve
          @watch = AcceptWatch.new(target: -> { @thread })
        end

        # Starts the loop and its watch on background threads.
        # @return [AcceptLoop] self
        def start
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

            socket = @listener.accept_nonblock(exception: false)
            Thread.new(socket) { |accepted| @serve.call(accepted) } unless socket == :wait_readable
          end
        rescue IOError, Errno::EBADF
          nil
        end
      end
    end
  end
end
