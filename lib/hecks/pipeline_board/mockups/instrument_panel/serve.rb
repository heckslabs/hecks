# frozen_string_literal: true

require "json"
require "net/http"
require "socket"

# The instrument-panel mock-up of the Pipeline Board's main page, served on a spare local port.
#
# It answers the mock-up's four static files and passes `GET /api/state` through to the board on
# port 4747, because a page on another port cannot read the board from the browser. It sends the
# board nothing but that one read. The mock-up is a design sample: no domain loads this file.
class InstrumentPanelMockup
  FILES = {
    "/"          => "index.html",
    "/panel.css" => "panel.css",
    "/panel.js"  => "panel.js",
    "/staged.js" => "staged.js"
  }.freeze
  TYPES = {
    ".html" => "text/html; charset=utf-8",
    ".css"  => "text/css; charset=utf-8",
    ".js"   => "text/javascript; charset=utf-8"
  }.freeze
  JSON_TYPE = "application/json"

  # @param port [Integer] the local port the mock-up listens on
  # @param board [Integer] the local port of the board whose state it reads
  def initialize(port: 4757, board: 4747)
    @port = port
    @board = board
  end

  # Answers one request after another until the process is stopped.
  #
  # @return [void]
  def run
    server = TCPServer.new("127.0.0.1", @port)
    loop { answer(server.accept) }
  end

  # Reads one request from a client, writes its reply and closes the connection.
  #
  # @param client [TCPSocket] the accepted connection
  # @return [Integer, String] the bytes written, or the name of the error that dropped the client
  def answer(client)
    client.write(reply(*found(path_of(client))))
  rescue SystemCallError, IOError => e
    e.class.name
  ensure
    client.close
  end

  # The path a request asks for, read with its headers so the client is not cut off mid-send.
  #
  # @param client [TCPSocket] the accepted connection
  # @return [String] the request path without its query, empty when the request is malformed
  def path_of(client)
    target = client.gets.to_s.split[1].to_s
    nil until last_header?(client.gets)
    target.split("?").first.to_s
  end

  # Whether a line read from a request ends its headers: the blank line, or the end of the stream.
  #
  # @param line [String, nil] one line of the request
  # @return [Boolean]
  def last_header?(line)
    line.to_s.strip.empty?
  end

  # The status, content type and body for a path.
  #
  # @param path [String] the request path without its query
  # @return [Array<String>] status, content type and body
  def found(path)
    return board_state if path == "/api/state"

    name = FILES[path]
    return ["404 Not Found", "text/plain", "not part of the mock-up"] unless name

    ["200 OK", TYPES.fetch(File.extname(name)), File.read(File.join(__dir__, name))]
  end

  # The board's state, read from the board and passed through unchanged.
  #
  # @return [Array<String>] status, content type and body
  def board_state
    answer = Net::HTTP.start("127.0.0.1", @board, open_timeout: 2, read_timeout: 20) do |http|
      http.get("/api/state")
    end
    ["#{answer.code} #{answer.message}", JSON_TYPE, answer.body]
  rescue SystemCallError, Timeout::Error, IOError => e
    ["502 Bad Gateway", JSON_TYPE, JSON.generate(error: "the board on :#{@board} did not answer (#{e.class})")]
  end

  # One whole HTTP reply.
  #
  # @param status [String] the status line's code and reason
  # @param type [String] the content type
  # @param body [String] the body
  # @return [String]
  def reply(status, type, body)
    head = ["HTTP/1.1 #{status}", "Content-Type: #{type}", "Content-Length: #{body.bytesize}",
            "Cache-Control: no-store", "Connection: close"]
    "#{head.join("\r\n")}\r\n\r\n#{body}"
  end
end

InstrumentPanelMockup.new.run if $PROGRAM_NAME == __FILE__
