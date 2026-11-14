# frozen_string_literal: true

require "spec_helper"
require "socket"
require "timeout"
require "tmpdir"
require "hecks/pipeline_board/adapters/pipeline_web"

# The wiring diagram stays current: the graph is drawn again from the bluebook files when one of
# them changes, and the board's event stream says so, so an open page redraws without a reload.
RSpec.describe "the live wiring diagram" do
  def policy(name, heard, reaches) = double(name: name, event_qualifier: heard, reaches: reaches)

  def aggregate(name) = double(hecks_name: name, description: "", lifecycle: nil, queries: [], commands: [], ports: [])

  # A one-domain registry whose single policy is named `label`.
  def registry(label)
    book = double(name: "Hecks", policies: [policy(label, "Run", "Run.Start")], aggregates: [aggregate("Run")], modules: [])
    instance_double(Hecks::Runtime::Registry, bluebooks: { "Hecks" => book }, ports: {}, adapters: {})
  end

  def reading(label)
    Hecks::Adapters::PipelineBoard::WiringSource::Reading.new(registry(label).bluebooks, {}, {})
  end

  describe Hecks::Adapters::PipelineWiring do
    let(:source_class) do
      Struct.new(:stamp, :reading, :failure, :reads) do
        def read
          self.reads += 1
          raise failure if failure

          reading
        end
      end
    end
    let(:source) { source_class.new([1], nil, nil, 0) }
    let(:wiring) { described_class.new(registry: registry("Booted"), settings: { source: source, look_seconds: 0 }) }

    def labels = wiring.graph[:edges].map { |edge| edge[:label] }

    def edit(label)
      source.stamp = [source.stamp.first + 1]
      source.reading = reading(label)
    end

    it "draws the booted registry while no bluebook file has changed" do
      expect(labels).to eq(["Booted"])
    end

    it "does not read the files again while none has changed" do
      3.times { wiring.graph }
      expect(source.reads).to eq(0)
    end

    it "draws the graph again from the files once one has changed", :aggregate_failures do
      expect(labels).to eq(["Booted"])
      edit("Edited")
      expect(labels).to eq(["Edited"])
    end

    it "reads a changed file once, however often the graph is asked for" do
      wiring.graph
      edit("Edited")
      3.times { wiring.graph }
      expect(source.reads).to eq(1)
    end

    it "keeps the digest when a file changed but the wiring did not" do
      before = wiring.digest
      source.stamp = [2]
      source.reading = reading("Booted")
      expect(wiring.digest).to eq(before)
    end

    it "gives the graph a new digest when the wiring is different" do
      before = wiring.digest
      edit("Edited")
      expect(wiring.digest).not_to eq(before)
    end

    it "keeps the last graph and says why when a changed file cannot be read", :aggregate_failures do
      wiring.graph
      source.stamp = [2]
      source.failure = ArgumentError.new("unbalanced block")
      expect(labels).to eq(["Booted"])
      expect(wiring.problem).to eq("ArgumentError: unbalanced block")
    end

    def break_then_mend
      source.stamp = [2]
      source.failure = ArgumentError.new("broken")
      wiring.graph
      source.failure = nil
      edit("Mended")
    end

    it "draws a file that was broken once it is mended" do
      break_then_mend
      expect(labels).to eq(["Mended"])
    end

    it "serves the graph with its digest as one reading" do
      expect(wiring.reading).to include(:nodes, :edges, digest: wiring.digest)
    end
  end

  describe Hecks::Adapters::PipelineBoard::WiringSource do
    let(:dir) { Dir.mktmpdir("wiring-source") }
    let(:path) { File.join(dir, "one.bluebook") }
    let(:booted) do
      instance_double(Hecks::Runtime::Registry, bluebook_sources: { "One" => [path, path] }, root: dir, ports: {}, adapters: {})
    end
    let(:scratch) do
      <<~BLUEBOOK
        Hecks.bluebook "Scratch" do
          vision "A scratch domain."
          aggregate "Thing" do
            description "A thing."
            attribute :name, ThingName
            identified_by :name
            value_object("ThingName") { attribute :value, String }
          end
        end
      BLUEBOOK
    end

    after { FileUtils.rm_rf(dir) }

    def stamp = described_class.new(booted).stamp

    it "lists each file once" do
      expect(described_class.new(booted).paths).to eq([path])
    end

    it "changes its stamp when a file is edited" do
      File.write(path, "a")
      first = stamp
      File.write(path, "bb")
      expect(stamp).not_to eq(first)
    end

    it "marks a file that is gone" do
      expect(stamp).to eq([[path, nil, nil]])
    end

    it "reads the files into a registry of its own and boots nothing", :aggregate_failures do
      File.write(path, scratch)
      held = Hecks.current_registry
      expect(described_class.new(booted).read.bluebooks.keys).to eq(["Scratch"])
      expect(Hecks.current_registry).to equal(held)
    end
  end

  describe "the event stream" do
    # A hub whose reader is woken once for each look it makes, as a journal that grew would.
    def hub(wakes)
      instance_double(Hecks::Adapters::PipelineBoard::Hub, join: wakes, leave: nil, current: [])
    end

    # A state that counts its looks in `tick`, wakes the reader after each, and ends at `ticks`.
    def counting(ticks, tick, wakes)
      lambda do
        throw :done if (tick[0] += 1) >= ticks
        wakes << Hecks::Adapters::PipelineBoard::Hub::Wake.new(1, [], false)
        { events: [] }
      end
    end

    # What a reader is sent when the wiring's digest is `digests[tick]`, the last one holding after.
    def sent(digests, ticks)
      wakes = Queue.new
      tick = [-1]
      wiring = -> { { digest: digests[[tick.first, digests.size - 1].min] } }
      stream = Hecks::Adapters::PipelineBoard::Stream.new(state: counting(ticks, tick, wakes), hub: hub(wakes), wiring: wiring)
      [].tap { |events| catch(:done) { stream.each { |event| events << event } } }
    end

    it "says the wiring is drawn differently when its digest moves" do
      expect(sent(%w[a a b], 5).map { |event| event.dig(:wiring, :digest) }.compact).to eq(%w[a b])
    end

    it "says nothing while the digest holds" do
      expect(sent(%w[a], 5).count { |event| event.key?(:wiring) }).to eq(1)
    end

    it "says nothing when the wiring is unknown" do
      wiring = -> { { unknown: "no domain" } }
      wakes = Queue.new
      stream = Hecks::Adapters::PipelineBoard::Stream.new(state: counting(2, [-1], wakes), hub: hub(wakes), wiring: wiring)
      events = [].tap { |seen| catch(:done) { stream.each { |event| seen << event } } }
      expect(events.count { |event| event.key?(:wiring) }).to eq(0)
    end

    # What a reader is sent when the state reads as each of `states` in turn.
    def pushed(states)
      wakes = Queue.new
      state = counting(states.size, tick = [-1], wakes) >> ->(_) { states[tick.first] }
      stream = Hecks::Adapters::PipelineBoard::Stream.new(state: state, hub: hub(wakes))
      [].tap { |events| catch(:done) { stream.each { |event| events << event } } }
    end

    it "pushes each event the state lists once, oldest first, with no read of its own" do
      rows = [{ key: "b", name: "Second" }, { key: "a", name: "First" }]
      expect(pushed([{ events: rows }] * 3).filter_map { |event| event[:name] }).to eq(%w[First Second])
    end

    it "pushes an event again when the reactions to it change" do
      states = [[], ["Carry"]].map { |reactions| { events: [{ key: "a", name: "First", reactions: reactions }] } }
      expect(pushed(states).filter_map { |event| event[:reactions] }).to eq([[], ["Carry"]])
    end

    it "notes once that the events are unknown while the first read is in progress" do
      waiting = { events: Hecks::Adapters::PipelineBoard::Snapshot::WAITING }
      expect(pushed([waiting, waiting]).count { |event| event.key?(:unknown) }).to eq(1)
    end
  end

  describe "over a real socket" do
    let(:server) { board.open_at(0) }

    def board
      train = { name: "Train", state: "ok", count: "1", detail: "d" }
      stages = instance_double(Hecks::Adapters::PipelineStages, state: { stages: [] }, feed: [],
                                                                fill_tile: { unknown: "x" }, plan_tile: { unknown: "x" },
                                                                train_tile: train)
      wiring = double(reading: { nodes: [], edges: [], digest: "d1" })
      settings = { stages: stages, wiring: wiring, background: false, tap: quiet_journal }
      Hecks::Adapters::PipelineWeb.new(settings: settings)
    end

    after { server.stop }

    def quiet_journal = File.join(Dir.tmpdir, "no-such-events.jsonl")

    def open_stream
      TCPSocket.new("127.0.0.1", server.port).tap { |socket| socket.write("GET /api/events HTTP/1.1\r\nHost: x\r\n\r\n") }
    end

    def next_wiring(socket)
      Timeout.timeout(5) do
        loop do
          next unless socket.gets.to_s.start_with?("event: wiring")

          return JSON.parse(socket.gets.to_s.delete_prefix("data: "))
        end
      end
    end

    it "pushes a `wiring` event carrying the digest" do
      expect(next_wiring(open_stream).dig("wiring", "digest")).to eq("d1")
    end
  end
end
