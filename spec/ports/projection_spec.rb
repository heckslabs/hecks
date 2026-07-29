require "spec_helper"

RSpec.describe Hecksagain::Ports::Projection::Worker do
  ProjectionEntry = Hecksagain::Ports::Persistence::Entry

  it "does not create a worker when no projection binding exists" do
    registry = Object.new
    def registry.hecksagon(_domain) = nil
    aggregate = Struct.new(:name).new("Account")
    expect(Hecksagain::Ports::Projection.worker(registry, "Banking", aggregate)).to be_nil
  end

  class ProjectionStore
    attr_reader :aggregate

    def initialize(entries = [])
      @aggregate = Struct.new(:name).new("Account")
      @entries = entries
      @rows = {}
    end

    def entries = @entries
    def all = @rows.values
    def append(entry) = (@entries << entry; entry)
    def project(entry)
      entry.delete? ? @rows.delete(entry.id) : @rows[entry.id] = entry.state.dup
      entry
    end
    def reset! = (@entries.clear; @rows.clear; self)
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
      .to raise_error(Hecksagain::Runtime::WiringError, /does not match/)
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
