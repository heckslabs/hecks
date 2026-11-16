# frozen_string_literal: true

require "spec_helper"
require "socket"
require "hecks/pipeline_board/adapters/pipeline_web"

# What the board's accept loop records about itself: a stall of more than two seconds, once, with
# the threads' stacks and its end, so a probe refused while the process is up leaves a line in the
# log saying where the interpreter was.
RSpec.describe Hecks::Adapters::PipelineBoard::AcceptWatch do
  let(:logged) { [] }
  let!(:accepting) { Thread.new { Queue.new.pop } }
  let(:watch) do
    described_class.new(target: -> { accepting }, clock: -> { 0 }, log: ->(message) { logged << message })
  end

  after { accepting.kill }

  def check_at(*times) = times.each { |time| watch.check(time) }

  it "says nothing while the loop beats within the limit", :aggregate_failures do
    check_at(0.5, 1.0, 1.5)
    watch.beat
    expect(logged).to be_empty
  end

  it "logs a loop silent for longer than the limit, with the threads" do
    check_at(0.5, 3.0)
    expect(logged.first).to match(/accept loop silent for 3\.0s.*thread/m)
  end

  it "logs a stall once however many checks see it" do
    check_at(3.0, 3.5, 4.0)
    expect(logged.size).to eq(1)
  end

  it "logs when the loop runs again" do
    check_at(3.0)
    allow(watch).to receive(:beat).and_call_original
    watch.instance_variable_set(:@beat, 3.4)
    check_at(3.5)
    expect(logged.last).to eq("board: accept loop running again")
  end

  it "logs a watcher that woke late even when the loop beat since" do
    check_at(0.5)
    watch.instance_variable_set(:@beat, 5.0)
    check_at(6.0)
    expect(logged.first).to include("woke 5.0s late")
  end

  it "names the accept loop's stack apart from the other threads" do
    check_at(3.0)
    expect(logged.first).to include("accept loop (")
  end

  describe "on a server" do
    def served
      Hecks::Adapters::PipelineBoard::Server.new(port: 0, app: Object.new).start
    end

    def answer_of(server)
      TCPSocket.new("127.0.0.1", server.port).tap { |socket| socket.write("GET /nope HTTP/1.1\r\n\r\n") }.read
    end

    it "keeps answering and stops cleanly", :aggregate_failures do
      server = served
      expect(answer_of(server)).to include("404 Not Found")
      server.stop
      expect(server.join).not_to be_nil
    end
  end
end
