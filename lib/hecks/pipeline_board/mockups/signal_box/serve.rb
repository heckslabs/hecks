# frozen_string_literal: true

require "json"
require "net/http"
require "webrick"

# Serves the signal box mock-up of the Pipeline Board's main page on a spare local port and relays
# the board's state, so the page reads it from its own origin. It only reads the board.
class SignalBoxMockup
  # The board whose state the page draws.
  BOARD = URI("http://127.0.0.1:4747/api/state")

  # @param port [Integer] the local port to listen on
  def initialize(port)
    @server = WEBrick::HTTPServer.new(BindAddress: "127.0.0.1", Port: port, DocumentRoot: __dir__)
    @server.mount_proc("/api/state") { |_request, response| relay(response) }
  end

  # Serves until the process is interrupted or terminated.
  #
  # @return [void]
  def start
    %w[INT TERM].each { |signal| trap(signal) { @server.shutdown } }
    @server.start
  end

  private

  def relay(response)
    response["Content-Type"] = "application/json"
    response["Cache-Control"] = "no-store"
    response.body = Net::HTTP.get(BOARD)
  rescue SystemCallError, Timeout::Error => e
    response.status = 502
    response.body = JSON.generate(unknown: "the board on 4747 did not answer: #{e.class}")
  end
end

SignalBoxMockup.new(Integer(ENV.fetch("PORT", "4749"))).start if $PROGRAM_NAME == __FILE__
