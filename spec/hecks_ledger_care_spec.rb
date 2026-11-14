require "spec_helper"
require_relative "support/ledger_scratch"

# A beat of the clock asks whether the AgentRun journal is due its compaction: over the world's
# line it starts `SchemaRevision.Compact` for the AgentRun aggregate, under it or against a held
# file it only says why it waits, and the Tickets world declares the line.
RSpec.describe "the AgentRun ledger is compacted on a beat" do
  include LedgerScratch

  let(:path) { scratch_ledger(300) }
  let(:domain) { File.expand_path("../lib/hecks/hecks", __dir__) }

  after { FileUtils.rm_rf(File.dirname(path)) }

  def beat_over(entries:, held: false)
    registry = boot_hecks_in_memory(domain).registry
    weighing = Hecks::Adapters::LedgerWeighing.new(registry: registry_over(ledger_at(path), entries: entries))
    lookup = ->(port, _asked) { port.to_s == "Weighing" ? weighing : nil }
    Hecks::Runtime::AdapterLookup.standing_in(lookup) { beat(registry, held) }
    registry.event_log.map(&:name)
  end

  def beat(registry, held)
    dispatch = -> { Hecks::Runtime::Dispatcher.new(registry).dispatch_flat("Hecks::Heartbeat.Beat", beat: { value: "beat-1" }) }
    held ? while_held(path) { dispatch.call } : dispatch.call
  end

  it "starts the compaction when the journal is over the line", :aggregate_failures do
    names = beat_over(entries: 100)

    expect(names).to include("LedgerCareDue", "LedgerCareHeard", "CompactionRequested")
  end

  it "only says why it waits when the journal is under the line", :aggregate_failures do
    names = beat_over(entries: 1000)

    expect(names).to include("LedgerCareDeferred", "LedgerCareDeclined")
    expect(names).not_to include("CompactionRequested")
  end

  it "defers a held file by name and starts no compaction", :aggregate_failures do
    names = beat_over(entries: 100, held: true)

    expect(names).to include("LedgerCareDeferred")
    expect(names).not_to include("CompactionRequested")
  end

  it "declares the line and the wait as a world row, 20000 entries and a few seconds" do
    world = File.read(File.expand_path("../lib/hecks/hecks/tickets.world", __dir__))

    expect(world).to include('ledger_care "LedgerCare", entries: 20_000, wait_seconds: 3')
  end
end
