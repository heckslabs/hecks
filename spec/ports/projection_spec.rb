require "spec_helper"

RSpec.describe Hecks::Ports::Projection::Worker do
  ProjectionEntry = Hecks::Ports::Persistence::Entry

  it "does not create a worker when no projection binding exists" do
    registry = Object.new
    def registry.hecksagon(_domain) = nil
    aggregate = Struct.new(:name).new("Account")
    expect(Hecks::Ports::Projection.worker(registry, "Banking", aggregate)).to be_nil
  end

  class ProjectionStore
    LiveRecord = Struct.new(:id, :state)

    attr_reader :aggregate, :entries
    attr_accessor :compacted_through

    # Seeded entries are both appended and projected, same as a real adapter where the aggregate
    # table and its journal are always in sync — `refresh!` reads `all`, not `entries`, so a
    # fixture that only populated the journal would silently starve it.
    def initialize(seeded = [])
      @aggregate = Struct.new(:name).new("Account")
      @entries = []
      @rows = {}
      @compacted_through = 0
      seeded.each do |entry|
        append(entry)
        project(entry)
      end
    end

    def all = @rows.map { |id, state| LiveRecord.new(id, state) }

    def append(entry)
      @entries << entry
      entry
    end

    def project(entry)
      entry.delete? ? @rows.delete(entry.id) : @rows[entry.id] = entry.state.dup
      entry
    end

    def reset!
      @entries.clear
      @rows.clear
      self
    end
  end

  it "rebuilds an account projection from durable journal entries and reports a checkpoint" do
    authoritative = ProjectionStore.new([
                                          ProjectionEntry.new(operation: "save", id: "acct-ada", state: { balance: 500 })
                                        ])
    projection = ProjectionStore.new

    worker = described_class.new(authoritative, projection)
    expect(worker.catch_up!).to equal(projection)
    expect(worker.checkpoint).to eq(1)
    expect(projection.all.map(&:state)).to eq([{ balance: 500 }])
    expect(projection.entries.map(&:id)).to eq(["acct-ada"])
  end

  it "rebuilds under :refresh from current records alone, needing no journal history at all" do
    entry = ProjectionEntry.new(operation: "save", id: "acct-ada", state: { balance: 500 })
    authoritative = ProjectionStore.new([entry])
    authoritative.entries.clear # fully compacted away — :refresh must not need this
    projection = ProjectionStore.new

    described_class.new(authoritative, projection, policy: :refresh).catch_up!

    expect(projection.all.map(&:state)).to eq([{ balance: 500 }])
  end

  it "rejects a stale projection under the strict policy" do
    authoritative = ProjectionStore.new([
                                          ProjectionEntry.new(operation: "save", id: "acct-ada", state: { balance: 500 })
                                        ])
    projection = ProjectionStore.new([
                                       ProjectionEntry.new(operation: "save", id: "acct-ada", state: { balance: 450 })
                                     ])

    expect { described_class.new(authoritative, projection, policy: :strict).catch_up! }
      .to raise_error(Hecks::Runtime::WiringError, /does not match/)
  end

  it "rejects a stale projection under the strict policy given as a String, not only the bare Symbol" do
    authoritative = ProjectionStore.new([
                                          ProjectionEntry.new(operation: "save", id: "acct-ada", state: { balance: 500 })
                                        ])
    projection = ProjectionStore.new([
                                       ProjectionEntry.new(operation: "save", id: "acct-ada", state: { balance: 450 })
                                     ])

    expect { described_class.new(authoritative, projection, policy: "strict").catch_up! }
      .to raise_error(Hecks::Runtime::WiringError, /does not match/)
  end

  # An unrecognized policy must fail at construction; otherwise it would skip the
  # consistency check and append onto divergent history.
  it "refuses loudly, at construction, rather than silently skipping the consistency check for an unknown policy" do
    authoritative = ProjectionStore.new([
                                          ProjectionEntry.new(operation: "save", id: "acct-ada", state: { balance: 500 })
                                        ])
    projection = ProjectionStore.new([
                                       ProjectionEntry.new(operation: "save", id: "acct-ada", state: { balance: 450 })
                                     ])

    expect { described_class.new(authoritative, projection, policy: :strinct) }
      .to raise_error(ArgumentError, /unknown projection catch_up! policy/)

    # The divergent entry must be left untouched.
    expect(projection.entries.map { |e| e.state[:balance] }).to eq([450])
  end

  it "refreshes a projection after a crash without duplicating entries" do
    entry = ProjectionEntry.new(operation: "save", id: "acct-ada", state: { balance: 500 })
    authoritative = ProjectionStore.new([entry])
    projection = ProjectionStore.new([entry])
    projection.project(entry)

    worker = described_class.new(authoritative, projection, policy: :refresh)
    worker.catch_up!
    worker.catch_up!

    expect(projection.entries.map(&:id)).to eq(["acct-ada"])
    expect(projection.all.map(&:state)).to eq([{ balance: 500 }])
  end

  it "refuses :strict catch-up when the authoritative journal is compacted past what this projection consumed" do
    seeded = [
      ProjectionEntry.new(operation: "save", id: "acct-ada", state: { balance: 100 }),
      ProjectionEntry.new(operation: "save", id: "acct-ada", state: { balance: 200 })
    ]
    authoritative = ProjectionStore.new(seeded)
    authoritative.entries.clear # simulates compact_entries! deleting both rows
    authoritative.compacted_through = 2
    projection = ProjectionStore.new # never caught up at all

    expect { described_class.new(authoritative, projection, policy: :strict).catch_up! }
      .to raise_error(Hecks::Runtime::WiringError, /already.*compacted.*use :refresh instead/)
  end

  it "still succeeds under :strict when the projection already consumed everything compacted away" do
    e1 = ProjectionEntry.new(operation: "save", id: "acct-ada", state: { balance: 100 })
    e2 = ProjectionEntry.new(operation: "save", id: "acct-ada", state: { balance: 200 })
    e3 = ProjectionEntry.new(operation: "save", id: "acct-ada", state: { balance: 300 })
    authoritative = ProjectionStore.new([e1, e2, e3])
    projection = ProjectionStore.new([e1, e2]) # already caught up through e2

    # simulates compact_entries!(through: 2): e1/e2 deleted, but this projection already
    # consumed them before they were compacted away, so it can still safely proceed.
    authoritative.entries.shift(2)
    authoritative.compacted_through = 2

    described_class.new(authoritative, projection, policy: :strict).catch_up!

    expect(projection.entries.map { |e| e.state[:balance] }).to eq([100, 200, 300])
    expect(projection.all.map(&:state)).to eq([{ balance: 300 }])
  end
end
