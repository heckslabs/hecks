# frozen_string_literal: true

module Hecks
  module Adapters
    module PipelineBoard
      # The sockets the board is serving: it counts them in up to a limit, sheds the connection
      # beyond it with a 503 that never waits on the peer, and closes them all when the board stops.
      class Connections
        SHED = "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"

        # @param limit [Integer] connections served at once
        def initialize(limit)
          @limit = limit
          @open = []
          @lock = Mutex.new
        end

        # Counts the socket in unless the limit is reached.
        # @return [Boolean] whether the socket may be served
        def admit(socket) = @lock.synchronize { @open.size < @limit && @open.push(socket) }

        # Closes the socket and counts it out.
        def release(socket)
          close(socket)
          @lock.synchronize { @open.delete(socket) }
        end

        # Answers a socket beyond the limit with a 503 and closes it.
        def shed(socket)
          socket.write_nonblock(SHED)
          socket.read_nonblock(4096, exception: false)
        rescue SystemCallError, IOError
          nil
        ensure
          close(socket)
        end

        # Closes every socket being served.
        def close_all = @lock.synchronize { @open.dup }.each { |socket| close(socket) }

        # @return [Boolean] whether the peer of a socket that was read to its request's end has
        #   hung up: the socket reads end of file or is reset
        def self.gone?(socket)
          socket.read_nonblock(1, exception: false).nil?
        rescue SystemCallError, IOError
          true
        end

        private

        def close(socket) = (socket.close unless socket.closed?)
      end
    end
  end
end
