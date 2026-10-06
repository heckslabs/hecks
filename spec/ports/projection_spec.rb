require "spec_helper"

RSpec.describe Hecks::Ports::Projection::Worker do
  ProjectionEntry = Hecks::Ports::Persistence::Entry

  let(:entry) { save_entry(500) }
  let(:entries) { [100, 200, 300].map { |balance| save_entry(balance) } }

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

  def save_entry(balance) = ProjectionEntry.new(operation: "save", id: "acct-ada", state: { balance: balance })

  def store_with(*balances) = ProjectionStore.new(balances.map { |balance| save_entry(balance) })

  def balances_of(store) = store.entries.map { |entry| entry.state[:balance] }

  def catch_up!(authoritative, projection, **options)
    described_class.new(authoritative, projection, **options).catch_up!
  end

  describe "rebuilding an account projection from durable journal entries" do
    let(:projection) { ProjectionStore.new }
    let(:worker) { described_class.new(store_with(500), projection) }

    it "answers the projection" do
      expect(worker.catch_up!).to equal(projection)
    end

    it "reports a checkpoint" do
      worker.catch_up!

      expect(worker.checkpoint).to eq(1)
    end

    it "rebuilds the records and the journal", :aggregate_failures do
      worker.catch_up!

      expect(projection.all.map(&:state)).to eq([{ balance: 500 }])
      expect(projection.entries.map(&:id)).to eq(["acct-ada"])
    end
  end

  it "rebuilds under :refresh from current records alone, needing no journal history at all" do
    authoritative = store_with(500)
    authoritative.entries.clear # fully compacted away — :refresh must not need this
    projection = ProjectionStore.new

    catch_up!(authoritative, projection, policy: :refresh)

    expect(projection.all.map(&:state)).to eq([{ balance: 500 }])
  end

  it "rejects a stale projection under the strict policy" do
    expect { catch_up!(store_with(500), store_with(450), policy: :strict) }
      .to raise_error(Hecks::Runtime::WiringError, /does not match/)
  end

  it "rejects a stale projection under the strict policy given as a String, not only the bare Symbol" do
    expect { catch_up!(store_with(500), store_with(450), policy: "strict") }
      .to raise_error(Hecks::Runtime::WiringError, /does not match/)
  end

  # An unrecognized policy must fail at construction; otherwise it would skip the
  # consistency check and append onto divergent history.
  describe "an unknown policy" do
    let(:projection) { store_with(450) }

    it "refuses loudly, at construction, rather than silently skipping the consistency check; the divergent entry " \
       "stays untouched", :aggregate_failures do
      expect { described_class.new(store_with(500), projection, policy: :strinct) }
        .to raise_error(ArgumentError, /unknown projection catch_up! policy/)
      expect(balances_of(projection)).to eq([450])
    end
  end

  it "refreshes a projection after a crash without duplicating entries", :aggregate_failures do
    projection = ProjectionStore.new([entry]).tap { |store| store.project(entry) }
    worker = described_class.new(ProjectionStore.new([entry]), projection, policy: :refresh)
    2.times { worker.catch_up! }

    expect(projection.entries.map(&:id)).to eq(["acct-ada"])
    expect(projection.all.map(&:state)).to eq([{ balance: 500 }])
  end

  # Simulates compact_entries!(through:): the oldest rows are deleted from the journal.
  def compacted(store, through:)
    store.entries.shift(through)
    store.compacted_through = through
    store
  end

  it "refuses :strict catch-up when the authoritative journal is compacted past what this projection consumed" do
    authoritative = compacted(store_with(100, 200), through: 2)

    expect { catch_up!(authoritative, ProjectionStore.new, policy: :strict) } # never caught up at all
      .to raise_error(Hecks::Runtime::WiringError, /already.*compacted.*use :refresh instead/)
  end

  it "still succeeds under :strict when the projection already consumed everything compacted away",
     :aggregate_failures do
    authoritative = compacted(ProjectionStore.new(entries), through: 2)
    projection = ProjectionStore.new(entries.first(2)) # already caught up through the second entry
    catch_up!(authoritative, projection, policy: :strict)

    expect(balances_of(projection)).to eq([100, 200, 300])
    expect(projection.all.map(&:state)).to eq([{ balance: 300 }])
  end
end
