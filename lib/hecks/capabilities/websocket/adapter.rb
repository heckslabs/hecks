# Hecks::Capabilities::Websocket::Adapter
#
# Default WebSocket transport adapter using the `websocket` gem
# and a raw TCPServer. Handles the HTTP upgrade handshake and
# frame encoding/decoding. Swappable — replace with Faye,
# ActionCable, or any library that calls port.handle_open/close/message.
#
#   adapter = Websocket::Adapter.new(port, port: 4568)
#   adapter.start  # blocks, accepting connections
#
require "socket"

module Hecks
  module Capabilities
    module Websocket
      # Hecks::Capabilities::Websocket::Adapter
      #
      # Default TCP+websocket-gem transport. Swappable for any WS library.
      #
      class Adapter
        def initialize(port, listen_port:)
          @port = port
          @listen_port = listen_port
        end

        # Start accepting WebSocket connections. Blocks the calling thread.
        def start
          require "websocket"
          server = TCPServer.new("0.0.0.0", @listen_port)
          loop do
            client = server.accept
            Thread.new(client) { |sock| handle_connection(sock) }
          end
        rescue => e
          warn "[WebSocket] Server error: #{e.message}"
        end

        # Start in a background thread.
        #
        # @return [Thread]
        def start_async
          Thread.new { start }
        end

        private

        def handle_connection(sock)
          require "websocket"

          handshake = WebSocket::Handshake::Server.new
          handshake << sock.readpartial(4096)
          return sock.close unless handshake.valid?

          sock.write(handshake.to_s)
          sock.flush

          ws = Connection.new(sock, handshake.version)
          @port.handle_open(ws)

          loop do
            data = sock.readpartial(65536)
            break if data.nil? || data.empty?
            ws.receive(data).each do |msg|
              @port.handle_message(ws, msg)
            end
          end
        rescue EOFError, IOError, Errno::ECONNRESET
        ensure
          @port.handle_close(ws) if ws
          sock&.close rescue nil
        end
      end

      # Hecks::Capabilities::Websocket::Connection
      #
      # Thin wrapper around a TCP socket for WebSocket frame encoding/decoding.
      #
      class Connection
        def initialize(sock, version)
          @sock = sock
          @version = version
          @frame = WebSocket::Frame::Incoming::Server.new(version: version)
        end

        # Send a string as a WebSocket text frame.
        #
        # @param data [String]
        def send(data)
          frame = WebSocket::Frame::Outgoing::Server.new(
            version: @version, data: data, type: :text
          )
          @sock.write(frame.to_s)
          @sock.flush
        end

        # Feed raw bytes and return decoded text messages.
        #
        # @param raw [String] raw TCP bytes
        # @return [Array<String>] decoded text messages
        def receive(raw)
          @frame << raw
          messages = []
          while (msg = @frame.next)
            messages << msg.data if msg.type == :text
          end
          messages
        end
      end
    end
  end
end
