# frozen_string_literal: true

require "spec_helper"
require "timeout"
require "hecks/pipeline_board/adapters/pipeline_web"

# What a board under test needs to count what it holds open and to stand in for its app.
module DescriptorLeakHelpers
  # A hub with no journal behind it: readers join and leave, and nothing ever wakes them.
  class QuietHub
    def join = Queue.new
    def leave(_queue) = nil
    def current = []
  end

  # An app whose stream is the board's own {Stream} over the quiet hub.
  class StreamApp
    def stream(**, &)
      Hecks::Adapters::PipelineBoard::Stream.new(hub: QuietHub.new, **).each(&)
    end

    def page = "<html></html>"
  end

  def descriptors = Dir.children("/dev/fd").size

  def open_to(server, request)
    TCPSocket.new(server.address, server.port).tap { |socket| socket.write(request) if request }
  end

  def rested?(descriptors_then, threads_then)
    pause = Queue.new
    Timeout.timeout(5) { pause.pop(timeout: 0.05) until at_rest?(descriptors_then, threads_then) }
    true
  rescue Timeout::Error
    false
  end

  def at_rest?(descriptors_then, threads_then)
    descriptors <= descriptors_then && Thread.list.size <= threads_then
  end

  def closed_by_board?(client) = Timeout.timeout(3) { client.read } == ""

  def shed_answer(server)
    Timeout.timeout(5) do
      loop do
        answer = open_to(server, "GET / HTTP/1.1\r\n\r\n").read
        return answer if answer.start_with?("HTTP/1.1 503")
      rescue SystemCallError
        next
      end
    end
  end
end

RSpec.describe "the board after pages are opened and abandoned" do
  include DescriptorLeakHelpers

  let(:server) { Hecks::Adapters::PipelineBoard::Server.new(port: 0, app: DescriptorLeakHelpers::StreamApp.new).start }
  let(:board) { "Hecks::Adapters::PipelineBoard::Server" }

  after { server.stop }

  context "with readers that went away" do
    let!(:resting) { server && [descriptors, Thread.list.size] }
    let(:clients) { Array.new(20) { open_to(server, "GET /api/events HTTP/1.1\r\n\r\n") } }

    it "frees the descriptors and threads of their streams" do
      clients.each { |client| client.readpartial(64) }
      clients.each(&:close)
      expect(rested?(*resting)).to be(true)
    end
  end

  it "closes a connection that never says what it wants" do
    stub_const("#{board}::READ_SECONDS", 0.3)
    expect(closed_by_board?(open_to(server, nil))).to be(true)
  end

  it "closes a connection that stalls in the middle of its headers" do
    stub_const("#{board}::READ_SECONDS", 0.3)
    expect(closed_by_board?(open_to(server, "GET / HTTP/1.1\r\nHost: x\r\n"))).to be(true)
  end

  it "sheds a connection beyond the cap with a 503" do
    stub_const("#{board}::MAX_CONNECTIONS", 3)
    held = Array.new(3) { open_to(server, nil) }
    expect(shed_answer(server)).to start_with("HTTP/1.1 503")
    held.each(&:close)
  end
end
