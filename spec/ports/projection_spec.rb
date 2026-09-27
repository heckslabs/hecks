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
    attr_reader :aggregate, :entries

    def initialize(entries = [])
      @aggregate = Struct.new(:name).new("Account")
      @entries = entries
      @rows = {}
    end

    def all = @rows.values

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
    expect(projection.all).to eq([{ balance: 500 }])
    expect(projection.entries.map(&:id)).to eq(["acct-ada"])
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
    expect(projection.all).to eq([{ balance: 500 }])
  end
end
