require "spec_helper"
require "socket"
require "hecks/adapters/driving/resident/client"

# How a launcher line met the resident, as the client notes it for the usage log: which of the
# outcomes each branch of the client ends in. No resident starts: the asking and the spawning are
# stood in for, and the conversation runs over a socket pair.
RSpec.describe "the client's resident outcome" do
  let(:resident) { Hecks::Adapters::Driving::Resident }
  let(:client) { resident::Client }
  let(:script) { File.expand_path("../exe/hecks", __dir__) }

  around do |example|
    saved = ENV.to_h.slice("HECKS_RESIDENT_OUTCOME", "HECKS_NO_RESIDENT")
    ENV.delete("HECKS_RESIDENT_OUTCOME")
    ENV.delete("HECKS_NO_RESIDENT")
    example.run
    ENV.delete("HECKS_RESIDENT_OUTCOME")
    ENV.update(saved)
  end

  def outcome = ENV.fetch("HECKS_RESIDENT_OUTCOME", nil)

  # @return [Integer, nil] the status the block ends the process with, nil when it returns
  def exit_status
    yield
    nil
  rescue SystemExit => e
    e.status
  end

  def stand_in(reason: nil, asked: [nil, nil], spawned: "started")
    allow(resident::Paths).to receive(:unusable_reason).and_return(reason)
    allow(client).to receive_messages(ask: asked, spawn_resident: spawned)
  end

  describe "run" do
    it "notes bypass for a line the launcher always runs itself" do
      ENV["HECKS_NO_RESIDENT"] = "1"
      client.run(script)
      expect(outcome).to eq("bypass")
    end

    it "notes unstable when the cache root changes from one launcher to the next" do
      stand_in(reason: "unstable")
      client.run(script)
      expect(outcome).to eq("unstable")
    end

    it "notes why a root may not be asked", :aggregate_failures do
      stand_in(reason: "path")
      client.run(script)
      expect(outcome).to eq("refused:path")
    end

    it "notes the reason the resident gave for not serving the line" do
      stand_in(asked: [nil, "changed"])
      client.run(script)
      expect(outcome).to eq("refused:changed")
    end

    it "notes what starting a resident came to when there was none to ask", :aggregate_failures do
      stand_in(spawned: "started")
      client.run(script)
      expect(outcome).to eq("started")
    end

    it "notes none when a resident is only coming up" do
      stand_in(spawned: "none")
      client.run(script)
      expect(outcome).to eq("none")
    end

    it "ends the launcher with the status when the resident ran the line" do
      stand_in(asked: [3, nil])
      expect(exit_status { client.run(script) }).to eq(3)
    end
  end

  describe "the conversation" do
    let(:ends) { UNIXSocket.pair }

    # Plays the resident: takes the request and the three streams, answers with `words`, and
    # hangs up when it has none.
    def resident_says(*words)
      Thread.new do
        take_line(ends.last)
        words.each { |word| resident::Wire.reply(ends.last, word) }
        ends.last.close if words.empty?
      end
    end

    def take_line(socket)
      resident::Wire.read_request(socket, seconds: 3)
      3.times { socket.recv_io }
    end

    it "answers the status and no reason once the resident ran the line" do
      resident_says("ready", "status:4")
      expect(client.converse(ends.first, script)).to eq([4, nil])
    end

    it "answers the reason a stale resident names", :aggregate_failures do
      resident_says("stale:env")
      expect(client.converse(ends.first, script)).to eq([nil, "env"])
    end

    it "answers dropped when the resident hung up on the request" do
      resident_says
      expect(client.converse(ends.first, script)).to eq([nil, "dropped"])
    end
  end
end
