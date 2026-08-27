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

  # Before this fix, ANY policy other than the exact Symbol `:strict`
  # (a typo, or any other spelling meaning the same thing) silently fell
  # through the consistency check and appended onto divergent history —
  # no error, no refresh, just a wrong answer built on top of a mismatch.
  # `:refresh` and `:strict` are the only two policies anything in this
  # codebase ever passes (`bin/project`, every spec) — there is no third,
  # legitimate policy to silently fall back to, so an unrecognized one
  # now refuses loudly, at construction, before it can touch any data.
  it "refuses loudly, at construction, rather than silently skipping the consistency check for an unknown policy" do
    authoritative = ProjectionStore.new([
                                          ProjectionEntry.new(operation: "save", id: "acct-ada", state: { balance: 500 })
                                        ])
    projection = ProjectionStore.new([
                                       ProjectionEntry.new(operation: "save", id: "acct-ada", state: { balance: 450 })
                                     ])

    expect { described_class.new(authoritative, projection, policy: :strinct) }
      .to raise_error(ArgumentError, /unknown projection catch_up! policy/)

    # And the append the old code performed silently must not have
    # happened either — the divergent entry stays exactly as it was.
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
