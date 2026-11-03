# frozen_string_literal: true

require "spec_helper"
require "net/http"
require "socket"
require "timeout"
require_relative "support/pipeline_board_world"
require "hecks/pipeline_board/adapters/pipeline_web"

# The board's server over a real socket on an ephemeral port: it binds the loopback address only,
# answers three GET routes and nothing else, pushes journal events in order, and writes nothing.
RSpec.describe Hecks::Adapters::PipelineWeb do
  let(:dir) { Dir.mktmpdir("board-web") }
  let(:log) { File.join(dir, "events.jsonl") }
  let!(:server) { board.open_at(0) }

  after do
    server.stop
    FileUtils.rm_rf(dir)
  end

  def names = ["Work items", "Sessions", "Local main", "Train", "CI", "Promote", "Release"]

  def board
    journal = Hecks::Adapters::PipelineJournal.new(settings: { trace: ->(*) { { events: [] } }, tap: log, ttl: 0 })
    rows = names.map { |name| { name: name, state: "ok", count: "1", detail: "d" } }
    stages = instance_double(Hecks::Adapters::PipelineStages, state: { stages: rows })
    allow(stages).to receive(:feed) { journal.recent(40) }
    described_class.new(settings: { stages: stages, background: false, interval: 0.05 })
  end

  def line(name, at) = JSON.generate("at" => at, "aggregate" => "Landing", "id" => "l1", "event" => name)

  def append(name, at) = File.write(log, "#{line(name, at)}\n", mode: "a")

  def request(verb, path)
    Net::HTTP.start("127.0.0.1", server.port) { |http| http.send_request(verb, path) }
  end

  def open_stream
    socket = TCPSocket.new("127.0.0.1", server.port)
    socket.write("GET /api/events HTTP/1.1\r\nHost: x\r\n\r\n")
    socket
  end

  def next_event(socket)
    Timeout.timeout(5) do
      text = socket.gets.to_s until text.to_s.start_with?("data:")
      JSON.parse(text.delete_prefix("data: "))
    end
  end

  it "binds the loopback address only" do
    expect(server.address).to eq("127.0.0.1")
  end

  it "answers /api/state with JSON holding every stage" do
    body = JSON.parse(request("GET", "/api/state").body)
    expect(body["stages"].map { |row| row["name"] }).to eq(names)
  end

  it "serves the page at /" do
    expect(request("GET", "/").body).to include("Pipeline Board")
  end

  it "answers 404 for any other path" do
    expect(request("GET", "/api/other").code).to eq("404")
  end

  it "answers 405 to any method but GET" do
    codes = %w[POST PUT DELETE PATCH].map { |verb| request(verb, "/api/state").code }
    expect(codes).to eq(%w[405] * 4)
  end

  it "has no external URL in the page" do
    expect(File.read(described_class::PAGE)).not_to match(%r{https?://|//cdn|@import})
  end

  def names_in_order
    append("LandingRequested", "2026-11-02T10:00:00Z")
    socket = open_stream
    first = next_event(socket)
    append("BranchLanded", "2026-11-02T10:00:05Z")
    [first["name"], next_event(socket)["name"]]
  ensure
    socket&.close
  end

  def reaction_of_logged_event
    File.write(log, "#{JSON.generate("at" => "2026-11-02T10:00:00Z", "event" => "AddRequested", "aggregate" => "LinkedTree",
                                     "id" => "t", "policy" => "AddWorktreeWhenRequested", "command" => "Create",
                                     "outcome" => "delivered", "emitted" => ["AddRecorded"])}\n")
    socket = open_stream
    next_event(socket)["reactions"]
  ensure
    socket&.close
  end

  it "pushes journal events as they are appended, oldest first" do
    expect(names_in_order).to eq(%w[LandingRequested BranchLanded])
  end

  it "carries the policy that reacted and the command it reached on a logged event" do
    expect(reaction_of_logged_event).to eq([{ "policy" => "AddWorktreeWhenRequested", "command" => "Create",
                                              "outcome" => "delivered", "emitted" => ["AddRecorded"] }])
  end

  it "keeps serving after a stream reader disconnects" do
    append("LandingRequested", "2026-11-02T10:00:00Z")
    open_stream.tap { |socket| next_event(socket) }.close
    expect(request("GET", "/api/state").code).to eq("200")
  end

  it "writes nothing: the log and the directory are as the test left them" do
    append("LandingRequested", "2026-11-02T10:00:00Z")
    before = [File.read(log), Dir.children(dir)]
    open_stream.tap { |socket| next_event(socket) }.close
    expect([File.read(log), Dir.children(dir)]).to eq(before)
  end
end
