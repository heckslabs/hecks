# Hecks::Appeal::WebSocketConnection
#
# WebSocket frame reader/writer using the `websocket` gem.
# Wraps a raw TCP socket with proper frame parsing and building.
#
#   ws = Hecks::Appeal::WebSocketConnection.new(tcp_socket, version)
#   ws.send('{"type":"event","event":"Connected"}')
#   msg = ws.read  # => '{"type":"command",...}'
#
require "websocket"

module Hecks
  module Appeal
    class WebSocketConnection
      def initialize(socket, version)
        @socket = socket
        @version = version
        @incoming = WebSocket::Frame::Incoming::Server.new(version: version)
      end

      # Read the next text message from the socket.
      #
      # @return [String, nil] the message text, or nil if closed
      def read
        loop do
          if (frame = @incoming.next)
            return nil if frame.type == :close
            return frame.data.force_encoding("UTF-8") if frame.type == :text
            next
          end

          data = @socket.readpartial(4096)
          return nil if data.nil? || data.empty?
          @incoming << data
        end
      rescue EOFError, IOError, Errno::ECONNRESET
        nil
      end

      # Send a text frame to the client.
      #
      # @param text [String] the message to send
      # @return [void]
      def send(text)
        frame = WebSocket::Frame::Outgoing::Server.new(
          version: @version, data: text, type: :text
        )
        @socket.write(frame.to_s)
        @socket.flush
      rescue IOError, Errno::EPIPE, Errno::ECONNRESET
        # Connection closed
      end
    end
  end
end
