require "hecks"
require "tmpdir"
require_relative "../../support/persistence_adapter_examples"

# Events older than a declared window are dropped from the shared event log while every
# follower's position, counted from the oldest event ever recorded, keeps its meaning.
RSpec.describe Hecks::Adapters::Sqlite, "event compaction" do
  include_context "with the Pizzas Order adapter helpers"

  around do |example|
    @dir = Dir.mktmpdir("hecks-sqlite-events-")
    example.run
  ensure
    FileUtils.remove_entry(@dir) if @dir
  end

  before(:context) { @aggregate = boot_in_memory.registry.bluebook("Pizzas").aggregate("Order") }

  let(:adapter) { described_class.new(aggregate: @aggregate, settings: { database: "pizzas.db" }, root: @dir) }
  let(:cutoff) { "2026-01-01T00:00:02Z" }

  before { 4.times { |n| adapter.record_event(pizza_purchased("p#{n}", "c#{n}", "2026-01-01T00:00:0#{n}Z")) } }

  it "drops the events recorded before the cutoff and reports how many" do
    expect(adapter.compact_events!(before: cutoff)).to eq(2)
  end

  it "keeps the events at and after the cutoff", :aggregate_failures do
    adapter.compact_events!(before: cutoff)

    expect(adapter.events.map(&:id)).to eq(%w[p2 p3])
    expect(adapter.event_count).to eq(4)
  end

  it "keeps a follower's position meaning the same events" do
    adapter.compact_events!(before: cutoff)

    expect(adapter.events_past(3).map(&:id)).to eq(%w[p3])
  end

  it "gives a follower behind the dropped events what is left" do
    adapter.compact_events!(before: cutoff)

    expect(adapter.events_past(0).map(&:id)).to eq(%w[p2 p3])
  end

  it "counts the dropped events across two compactions", :aggregate_failures do
    adapter.compact_events!(before: cutoff)
    adapter.compact_events!(before: "2026-01-01T00:00:03Z")

    expect(adapter.event_count).to eq(4)
    expect(adapter.events_past(3).map(&:id)).to eq(%w[p3])
  end

  it "keeps the dropped count when the database is reopened" do
    adapter.compact_events!(before: cutoff)
    reopened = described_class.new(aggregate: @aggregate, settings: { database: "pizzas.db" }, root: @dir)

    expect(reopened.event_count).to eq(4)
  end

  it "counts what a cutoff would drop without dropping it", :aggregate_failures do
    expect(adapter.events_before(cutoff)).to eq(2)
    expect(adapter.events.size).to eq(4)
  end

  it "drops nothing and counts nothing when the delete fails midway", :aggregate_failures do
    allow(adapter.instance_variable_get(:@db)).to receive(:execute).and_call_original
    allow(adapter.instance_variable_get(:@db)).to receive(:execute)
      .with(a_string_matching(/hecks_event_compaction/), anything).and_raise(SQLite3::Exception, "boom")

    expect { adapter.compact_events!(before: cutoff) }.to raise_error(SQLite3::Exception)
    expect(adapter.events.size).to eq(4)
  end
end
