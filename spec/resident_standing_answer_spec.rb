# frozen_string_literal: true

require "spec_helper"
require "socket"
require "hecks/adapters/driving/resident/client"
require "hecks/pipeline_board/adapters/pipeline_web"

# The launcher's answer to `PipelineBoard.snapshot` from a running board: it asks the board's
# `/api/snapshot` over a plain socket and prints the panel, so the line boots nothing; a board that
# is down or not holding a state leaves the line to the launcher.
RSpec.describe Hecks::Adapters::Driving::Resident::StandingAnswer do
  let(:board) { TCPServer.new("127.0.0.1", 0) }
  let(:asked) { [] }

  after { board.close unless board.closed? }

  def answering(status, body)
    Thread.new do
      socket = board.accept
      asked << socket.gets
      nil until ["\r\n", ""].include?(socket.gets.to_s)
      socket.write("HTTP/1.1 #{status}\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
      socket.close
    end
  end

  def answer(*argv, status: "200 OK", body: "panel\n")
    answering(status, body)
    stub_const("ENV", ENV.to_h.merge(described_class::PORT_VARIABLE => board.addr[1].to_s))
    described_class.answer(argv)
  end

  it "prints the board's panel for the snapshot line" do
    expect(answer("pipeline_board", "PipelineBoard.snapshot", "width.value=120")).to eq("panel\n")
  end

  it "passes the line's width, colour and limit to the board" do
    answer("PipelineBoard.snapshot", "width.value=120", "colour=true", "limit.value=5", "--wait")
    expect(asked.first).to start_with("GET /api/snapshot?width=120&colour=true&limit=5 ")
  end

  it "leaves the line to the launcher when the board has no state yet" do
    expect(answer("PipelineBoard.snapshot", status: "503 Service Unavailable", body: "none")).to be_nil
  end

  it "strips control characters but the colour escape from the board's answer" do
    expect(answer("PipelineBoard.snapshot", body: "a\u0007b\e[32mc\n")).to eq("ab\e[32mc\n")
  end

  it "leaves the line to the launcher when no board listens" do
    port = board.addr[1].tap { board.close }
    stub_const("ENV", ENV.to_h.merge(described_class::PORT_VARIABLE => port.to_s))
    expect(described_class.answer(["PipelineBoard.snapshot"])).to be_nil
  end

  it "asks the default port when the port variable is not a number" do
    stub_const("ENV", ENV.to_h.merge(described_class::PORT_VARIABLE => "board"))
    expect(described_class.port).to eq(described_class::PORT)
  end

  ["PipelineBoard.stages", "PipelineBoard.snapshot --help", "PipelineBoard.snapshot extra=1"].each do |line|
    it "does not ask the board for #{line}" do
      expect(described_class.asked(line.split)).to be_nil
    end
  end

  it "ends the launcher's line with the board's answer before a resident is asked" do
    hide_const("Hecks::Adapters::Driving::Resident::CHILD")
    allow(Hecks::Adapters::Driving::Resident::Client).to receive(:bypass?).and_return(false)
    allow(described_class).to receive(:answer).and_return("panel\n")
    launched = -> { Hecks::Adapters::Driving::Resident::Client.run("exe/hecks") }
    expect(launched).to raise_error(SystemExit).and output("panel\n").to_stdout
  end

  it "loads nothing past the standard library, so the answered line boots nothing" do
    source = File.read(File.expand_path("../lib/hecks/adapters/driving/resident/standing_answer.rb", __dir__))
    expect(source.scan(/^require "([^"]+)"/).flatten).to eq(%w[socket io/wait])
  end

  it "asks the port the bluebook's PipelineBoard.Serve declares, which the board opens on", :aggregate_failures do
    source = File.read(File.expand_path("../lib/hecks/pipeline_board/pipeline_board.bluebook", __dir__))
    declared = Integer(source[/command "Serve" do.*?attribute :port, Port, default: (\d+)/m, 1])
    expect(described_class::PORT).to eq(declared)
    expect(Hecks::Adapters::PipelineWeb::DEFAULT_PORT).to eq(declared)
  end
end
