# frozen_string_literal: true

require "base64"
require "json"
require "net/http"
require "openssl"
require "securerandom"
require "socket"
require "uri"

module Hecks
  module Adapters
    # A minimal WebSocket client over a TLS socket, for Slack Socket Mode: it opens the URL Slack
    # issues for an app token, reads text frames (answering pings) and writes masked text frames.
    # It answers `read` with the next text frame, nil once the server closes.
    class SlackSocket
      # Raised when Slack will not open a connection for the app token.
      class Refused < StandardError; end

      OPEN_URL = "https://slack.com/api/apps.connections.open"

      # @param app_token [String] the Socket Mode app-level token
      # @return [SlackSocket] connected
      # @raise [RuntimeError] when Slack refuses the token
      def self.open(app_token)
        reply = Net::HTTP.post(URI(OPEN_URL), "", "Authorization" => "Bearer #{app_token}")
        body = JSON.parse(reply.body)
        raise Refused, "slack refused the app token: #{body["error"]}" unless body["ok"]

        new(connect(URI(body["url"])))
      end

      # @param uri [URI] the wss address
      # @return [OpenSSL::SSL::SSLSocket] past the upgrade handshake
      def self.connect(uri)
        io = OpenSSL::SSL::SSLSocket.new(TCPSocket.new(uri.host, uri.port || 443)).tap(&:connect)
        key = Base64.strict_encode64(SecureRandom.random_bytes(16))
        io.write("GET #{uri.request_uri} HTTP/1.1\r\nHost: #{uri.host}\r\nUpgrade: websocket\r\n" \
                 "Connection: Upgrade\r\nSec-WebSocket-Key: #{key}\r\nSec-WebSocket-Version: 13\r\n\r\n")
        skip_headers(io)
        io
      end

      # Reads past the response headers, up to their blank line.
      def self.skip_headers(io)
        line = io.gets
        line = io.gets while line && !line.strip.empty?
      end

      # @param io [#read, #write] a connection already upgraded
      def initialize(io)
        @io = io
      end

      # @return [String, nil] the next text frame, or nil when closed
      def read
        loop do
          opcode, payload = frame
          return nil if opcode.nil? || opcode == 8
          return payload if opcode == 1

          send_frame(10, payload) if opcode == 9
        end
      end

      # @param text [String] sent as one masked text frame
      def write(text) = send_frame(1, text)

      private

      def frame
        head = @io.read(2) or return nil
        length = head.getbyte(1) & 0x7f
        length = @io.read(2).unpack1("n") if length == 126
        length = @io.read(8).unpack1("Q>") if length == 127
        [head.getbyte(0) & 0x0f, @io.read(length).to_s.force_encoding("UTF-8")]
      end

      def send_frame(opcode, payload)
        mask = SecureRandom.random_bytes(4)
        @io.write([0x80 | opcode].pack("C") + length_of(payload.bytesize) + mask + masked(payload, mask))
      end

      def masked(payload, mask)
        bytes = payload.b.bytes
        bytes.each_with_index.map { |byte, i| byte ^ mask.getbyte(i % 4) }.pack("C*")
      end

      def length_of(size)
        return [0x80 | size].pack("C") if size < 126

        size < 65_536 ? [0x80 | 126, size].pack("Cn") : [0x80 | 127, size].pack("CQ>")
      end
    end
  end
end
