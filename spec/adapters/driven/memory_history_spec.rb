require "spec_helper"
require "tmpdir"
require "fileutils"

# A Memory-backed aggregate whose `list_of` grows by one entry per command: the cost of a save
# follows what changed, not how long the history is, and sharing the unchanged entries between
# journal entries and records never lets a caller reach journalled state.
RSpec.describe "Memory with a growing list" do
  HISTORY_BLUEBOOK = <<~RUBY.freeze
    Hecks.bluebook "History" do
      vision "An aggregate whose state carries a growing list of snapshots."
      supporting

      aggregate "Run" do
        description "A run holding 32 markers and one snapshot of them per step."
        attribute :label, Label
        attribute :tick, Tick
        attribute :markers, list_of(Marker)
        attribute :snapshots, list_of(Snapshot)
        identified_by :label

        value_object "Label" do
          attribute :value, String
        end

        value_object "Tick" do
          attribute :value, Integer, default: 0
        end

        value_object "MarkerId" do
          attribute :value, String
        end

        value_object "Cell" do
          attribute :column, Integer
          attribute :row, Integer
        end

        entity "Marker" do
          attribute :id, MarkerId
          attribute :cell, Cell
          identified_by :id
        end

        value_object "Snapshot" do
          attribute :tick, Tick
          attribute :markers, list_of(Marker)
        end

        command "Open" do
          goal "Open a run"
          attribute :label, Label
        end

        command "Place" do
          goal "Put a marker down"
          reference_to Run
          attribute :id, MarkerId
          attribute :cell, Cell
          sets :markers, append: { id: :id, cell: :cell }
          emits "Placed"
        end

        command "Advance" do
          goal "One more tick; remember the markers as they stand"
          reference_to Run
          sets :tick, increment: { value: 1 }
          sets :snapshots, append: { tick: state(:tick), markers: state(:markers) }
          emits "Advanced"
        end
      end
    end
  RUBY

  around do |example|
    @dir = Dir.mktmpdir("memory-history")
    FileUtils.mkdir_p(File.join(@dir, "bluebook"))
    File.write(File.join(@dir, "bluebook/history.bluebook"), HISTORY_BLUEBOOK)
    File.write(File.join(@dir, "bluebook/history.hecksagon"),
               %(Hecks.hecksagon "History" do\n  History::Run.persisted_by("Memory")\nend\n))
    example.run
  ensure
    FileUtils.rm_rf(@dir)
  end

  let(:runtime) { Hecks.boot(@dir, install_doors: false) }
  let(:aggregate) { runtime.registry.bluebook("History").aggregate("Run") }
  let(:repository) { runtime.registry.repository("History", aggregate) }
  let(:codec) { Hecks::Ports::Persistence::StateCodec }

  def open_run(label = "r")
    runtime.dispatch_flat("History::Run.Open", label: { value: label })
    32.times do |i|
      runtime.dispatch_flat("History::Run.Place", label: label, id: { value: "m#{i}" },
                                                  cell: { column: i % 8, row: i / 8 })
    end
  end

  def advance(label = "r") = runtime.dispatch_flat("History::Run.Advance", label: label)

  def clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  # Objects allocated by `count` further steps, per step.
  def allocations_per_step(count)
    before = GC.stat(:total_allocated_objects)
    count.times { advance }
    (GC.stat(:total_allocated_objects) - before) / count.to_f
  end

  def seconds_per_step(count, label)
    started = clock
    count.times { advance(label) }
    (clock - started) / count
  end

  describe "growth" do
    it "allocates about the same per step at 200 recorded snapshots as at 20" do
      open_run
      19.times { advance }
      early = allocations_per_step(5)
      175.times { advance }
      late = allocations_per_step(5)

      expect(late).to be < early * 2
    end

    it "takes about the same time per step at 200 recorded snapshots as at 20" do
      ratios = Array.new(2) do |attempt|
        open_run("t#{attempt}")
        advance("t#{attempt}")
        early = seconds_per_step(5, "t#{attempt}")
        175.times { advance("t#{attempt}") }
        late = seconds_per_step(5, "t#{attempt}")
        late / early
      end

      expect(ratios.min).to be < 3
    end
  end

  describe "sharing between journal entries" do
    before do
      open_run
      3.times { advance }
    end

    it "journals each snapshot once, as one frozen node shared by every later entry" do
      saves = repository.entries.select { |entry| entry.id == "r" }
      first_snapshot = saves.last(3).first.state[:snapshots].first

      expect(saves.last.state[:snapshots].first).to equal(first_snapshot)
      expect(first_snapshot).to be_frozen
      expect(Hecks::Freezer.deeply_frozen?(first_snapshot)).to be(true)
    end

    it "journals the same shape a durable adapter would read back" do
      live = repository.find("r")

      expect(repository.entries.last.state).to eq(codec.copy(aggregate, live.state))
      expect(repository.entries.last.state[:snapshots].first).to be_a(Hash)
      expect(repository.entries.last.state[:snapshots].first.keys).to all(be_a(Symbol))
    end

    it "keeps the journal's key order and the list contents of every entry" do
      entry = repository.entries.last

      expect(entry.state.keys).to eq(codec.copy(aggregate, repository.find("r").state).keys)
      expect(entry.state[:snapshots].map { |snapshot| snapshot[:tick] }).to eq([{ value: 0 }, { value: 1 }, { value: 2 }])
      expect(entry.state[:markers].size).to eq(32)
    end
  end

  describe "aliasing" do
    before do
      open_run
      2.times { advance }
    end

    it "refuses an in-place change to a journalled element" do
      snapshot = repository.entries.last.state[:snapshots].first

      expect { snapshot[:tick] = { value: 99 } }.to raise_error(FrozenError)
      expect { repository.entries.last.state[:snapshots] << {} }.to raise_error(FrozenError)
    end

    it "leaves the journal alone when a returned instance's state is changed" do
      before = Marshal.load(Marshal.dump(repository.entries.map(&:state)))
      record = repository.find("r")

      record.state[:tick] = :changed
      expect { record.state[:snapshots] << :extra }.to raise_error(FrozenError)

      expect(repository.entries.map(&:state)).to eq(before)
    end

    it "shares no node between a record and the journal" do
      record = repository.find("r")
      journalled = repository.entries.last.state[:snapshots]

      expect(record.state[:snapshots].zip(journalled).map { |live, held| live.equal?(held) }).to all(be(false))
      expect(record.state[:snapshots].first).to be_a(Hecks::Runtime::Value)
    end

    it "does not share an element a caller may still change" do
      adapter = Hecks::Adapters::Memory.new(aggregate: aggregate)
      marker = { id: { value: "loose" }, cell: { column: 0, row: 0 } }
      state = { label: { value: "m" }, markers: [marker] }
      adapter.save(Hecks::Runtime::Instance.new(aggregate: aggregate, id: "m", state: state))

      marker[:cell] = { column: 7, row: 7 }

      expect(adapter.entries.last.state[:markers].first[:cell]).to eq(column: 0, row: 0)
      expect(adapter.find("m").state[:markers].first[:cell][:column]).to eq(0)
    end
  end

  describe "replay" do
    it "rebuilds identical records from the journal" do
      open_run
      4.times { advance }
      held = repository.find("r")

      replica = Hecks::Adapters::Memory.new(aggregate: aggregate)
      repository.entries.each { |entry| replica.project(entry) }
      rebuilt = replica.find("r")

      expect(rebuilt.to_h).to eq(held.to_h)
      expect(Hecks::Runtime::Value.materialize(rebuilt.to_h)).to eq(Hecks::Runtime::Value.materialize(held.to_h))
      expect(rebuilt.state.keys).to eq(held.state.keys)
    end

    it "gives a reset adapter nothing to reuse and still saves correctly" do
      open_run
      2.times { advance }
      repository.reset!
      open_run
      advance

      expect(repository.find("r")[:snapshots].size).to eq(1)
      expect(repository.entries.size).to eq(34)
    end
  end
end
