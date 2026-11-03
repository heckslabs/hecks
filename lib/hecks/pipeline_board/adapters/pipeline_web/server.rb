# frozen_string_literal: true

require "socket"
require "json"

module Hecks
  module Adapters
    module PipelineBoard
      # A small HTTP/1.1 server on the loopback address and nothing else. It answers three GET paths
      # (`/`, `/api/state`, `/api/events`) and refuses everything else, so no command and no write
      # is reachable through it. It serves one request per connection, and `/api/events` holds its
      # connection open as a Server-Sent Events stream.
      class Server
        HOST = "127.0.0.1"
        ROUTES = %w[/ /api/state /api/events /wiring /api/wiring /sequence].freeze
        STATUS = { 200 => "OK", 404 => "Not Found", 405 => "Method Not Allowed" }.freeze

        # @return [Integer] the port the server is bound to
        attr_reader :port

        # @return [String] the address the server is bound to
        attr_reader :address

        # @param port [Integer] 0 binds a free port
        # @param app [#page, #state, #stream] what answers the three routes
        def initialize(port:, app:)
          @listener = TCPServer.new(HOST, port)
          bound = @listener.local_address
          @address = bound.ip_address
          @port = bound.ip_port
          @app = app
          @open = []
        end

        # Starts accepting connections on a background thread.
        # @return [Server] self
        def start
          @thread = Thread.new { accept_loop }
          self
        end

        # Blocks until {#stop}.
        def join = @thread&.join

        # Closes the listener and every open stream.
        def stop
          @listener.close
          @open.each { |socket| socket.close unless socket.closed? }
        end

        private

        def accept_loop
          loop { Thread.new(@listener.accept) { |socket| serve(socket) } }
        rescue IOError, Errno::EBADF
          nil
        end

        def serve(socket)
          @open << socket
          verb, target = socket.gets.to_s.split
          nil while (line = socket.gets) && line != "\r\n"
          answer(socket, verb, target.to_s.split("?").first)
        rescue SystemCallError, IOError
          nil
        ensure
          socket.close unless socket.closed?
          @open.delete(socket)
        end

        def answer(socket, verb, path)
          return reply(socket, 405, "text/plain", "method not allowed", "Allow" => "GET") unless verb == "GET"
          return reply(socket, 404, "text/plain", "not found") unless ROUTES.include?(path)

          route(socket, path)
        end

        def route(socket, path)
          case path
          when "/" then reply(socket, 200, "text/html; charset=utf-8", @app.page)
          when "/api/state" then reply(socket, 200, "application/json", JSON.generate(@app.state))
          when "/wiring" then reply(socket, 200, "text/html; charset=utf-8", @app.wiring_page)
          when "/sequence" then reply(socket, 200, "text/html; charset=utf-8", @app.sequence_page)
          when "/api/wiring" then reply(socket, 200, "application/json", JSON.generate(@app.wiring))
          else stream(socket)
          end
        end

        def reply(socket, status, type, body, extra = {})
          head = { "Content-Type" => type, "Content-Length" => body.bytesize, "Cache-Control" => "no-store",
                   "Connection" => "close" }.merge(extra)
          socket.write("HTTP/1.1 #{status} #{STATUS.fetch(status)}\r\n#{headers(head)}\r\n#{body}")
        end

        def headers(head) = head.map { |key, value| "#{key}: #{value}\r\n" }.join

        def stream(socket)
          socket.write("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-store\r\n" \
                       "Connection: close\r\n\r\n")
          @app.stream { |event| socket.write("event: board\ndata: #{JSON.generate(event)}\n\n") }
        end
      end
    end
  end
end
