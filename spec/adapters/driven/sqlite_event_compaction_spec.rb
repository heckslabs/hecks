require "hecks"
require "tmpdir"
require_relative "../../support/persistence_adapter_examples"

# The shared `events` table of a Sqlite database, compacted past a window: the oldest events are
# dropped while every follower's count position stays where it was.
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

  it "drops the events older than the cutoff and reports how many" do
    expect(adapter.compact_events!(before: cutoff)).to eq(2)
  end

  it "keeps the events at or after the cutoff", :aggregate_failures do
    adapter.compact_events!(before: cutoff)

    expect(adapter.events.map(&:id)).to eq(%w[p2 p3])
    expect(adapter.events_dropped).to eq(2)
  end

  it "keeps the count a follower reads, as if nothing were dropped" do
    adapter.compact_events!(before: cutoff)

    expect(adapter.event_count).to eq(4)
  end

  it "reads past a position from before the compaction as it did", :aggregate_failures do
    adapter.compact_events!(before: cutoff)

    expect(adapter.events_past(3).map(&:id)).to eq(%w[p3])
    expect(adapter.events_past(4)).to eq([])
  end

  it "hands a follower behind the dropped events the ones that remain" do
    adapter.compact_events!(before: cutoff)

    expect(adapter.events_past(0).map(&:id)).to eq(%w[p2 p3])
  end

  it "adds to the dropped count when compacted again", :aggregate_failures do
    adapter.compact_events!(before: cutoff)

    expect(adapter.compact_events!(before: "2026-01-01T00:00:03Z")).to eq(1)
    expect(adapter.events_dropped).to eq(3)
  end

  it "drops nothing when no event is older than the cutoff", :aggregate_failures do
    expect(adapter.compact_events!(before: "2025-01-01T00:00:00Z")).to eq(0)
    expect(adapter.events_dropped).to eq(0)
  end

  it "leaves the events and the count as they were when the delete fails midway", :aggregate_failures do
    allow(adapter).to receive(:record_events_dropped!).and_raise(SQLite3::Exception, "disk full")

    expect { adapter.compact_events!(before: cutoff) }.to raise_error(SQLite3::Exception)
    expect(adapter.events.size).to eq(4)
  end
end
