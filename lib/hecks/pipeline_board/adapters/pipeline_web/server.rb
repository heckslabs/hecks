# frozen_string_literal: true

require "socket"
require "json"
require_relative "act_route"
require_relative "deep_links"

module Hecks
  module Adapters
    module PipelineBoard
      # A small HTTP/1.1 server on the loopback address and nothing else. It answers the pages,
      # scripts and JSON listed in `SERVED` and the `/api/events` stream, and refuses the rest.
      # The one write it takes is `POST /api/act`, a JSON body naming one step the app passes to
      # its `act`, which runs that
      # step's launcher command and nothing else. It serves one request per connection, and
      # `/api/events` holds its connection open as a Server-Sent Events stream.
      class Server
        HOST = "127.0.0.1"
        HTML_TYPE = "text/html; charset=utf-8"
        SCRIPT_TYPE = "text/javascript; charset=utf-8"
        JSON_TYPE = "application/json"
        # Each GET path but the stream: the type it answers with and the app method that reads it.
        SERVED = {
          "/"           => [HTML_TYPE, :page],
          "/wiring"     => [HTML_TYPE, :wiring_page],
          "/sequence"   => [HTML_TYPE, :sequence_page],
          "/agents"     => [HTML_TYPE, :agents_page],
          "/diagrams"   => [HTML_TYPE, :diagrams_page],
          "/stream.js"  => [SCRIPT_TYPE, :stream_script],
          "/answer.js"  => [SCRIPT_TYPE, :answer_script],
          "/api/state"  => [JSON_TYPE, :state],
          "/api/wiring" => [JSON_TYPE, :wiring]
        }.freeze
        ROUTES = [*SERVED.keys, "/api/events"].freeze
        STATUS = { 200 => "OK", 400 => "Bad Request", 403 => "Forbidden", 404 => "Not Found",
                   405 => "Method Not Allowed", 415 => "Unsupported Media Type",
                   422 => "Unprocessable Entity", 503 => "Service Unavailable" }.freeze

        # @return [Integer] the port the server is bound to
        attr_reader :port

        # @return [String] the address the server is bound to
        attr_reader :address

        # @param port [Integer] 0 binds a free port
        # @param app [#page, #state, #stream, #answer] what answers the routes
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
          headers = read_headers(socket)
          answer(socket, verb, target.to_s.split("?").first, headers)
        rescue SystemCallError, IOError
          nil
        ensure
          socket.close unless socket.closed?
          @open.delete(socket)
        end

        def read_headers(socket)
          headers = {}
          while (line = socket.gets) && line != "\r\n"
            key, value = line.split(":", 2)
            headers[key.to_s.downcase] = value.to_s.strip
          end
          headers
        end

        def answer(socket, verb, path, headers)
          return post(socket, path, headers) if verb == "POST" && path == ActRoute::PATH
          return reply(socket, 405, "text/plain", "method not allowed", "Allow" => "GET") unless verb == "GET"

          deep = DeepLinks.match(path)
          return reply(socket, *DeepLinks.answer(@app, deep)) if deep
          return reply(socket, 404, "text/plain", "not found") unless ROUTES.include?(path)

          route(socket, path)
        end

        def route(socket, path)
          return stream(socket) if path == "/api/events"

          type, reader = SERVED.fetch(path)
          body = @app.public_send(reader)
          reply(socket, 200, type, type == JSON_TYPE ? JSON.generate(body) : body)
        end

        # The one write the board takes: `POST /api/act`, judged by {ActRoute} before its body is
        # read. The origins allowed are the board's own, on 127.0.0.1 or localhost.
        def post(socket, path, headers)
          origins = ["http://#{@address}:#{@port}", "http://localhost:#{@port}"]
          refused = ActRoute.refusal(path, headers, origins)
          return reply(socket, refused[0], "text/plain", refused[1]) if refused

          status, body = ActRoute.submit(@app, socket.read(ActRoute.length_of(headers)).to_s)
          reply(socket, status, "application/json", JSON.generate(body))
        end

        def reply(socket, status, type, body, extra = {})
          head = { "Content-Type" => type, "Content-Length" => body.bytesize, "Cache-Control" => "no-store",
                   "Connection" => "close" }.merge(extra)
          socket.write("HTTP/1.1 #{status} #{STATUS.fetch(status)}\r\n#{headers(head)}\r\n#{body}")
        end

        def headers(head) = head.map { |key, value| "#{key}: #{value}\r\n" }.join

        # One server-sent event: a `state` push, a `wiring` change or a `board` event, each a JSON line.
        def sse(event)
          name = %w[state wiring].find { |kind| event.key?(kind.to_sym) } || "board"
          "event: #{name}\ndata: #{JSON.generate(event)}\n\n"
        end

        def stream(socket)
          socket.write("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-store\r\n" \
                       "Connection: close\r\n\r\n")
          @app.stream { |event| socket.write(sse(event)) }
        end
      end
    end
  end
end
