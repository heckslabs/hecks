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

    expect(world).to include('ledger_care "LedgerCare", entries: 20_000, wait_seconds: 3, outbox_hours: 1')
  end

  describe "the compaction is asked of the AgentRun bluebook's own directory" do
    let(:keeping) { Hecks::Adapters::LedgerKeeping }
    let(:home) { "/checkout/lib/hecks/hecks" }
    let(:bluebook) do
      agent_run = Struct.new(:hecks_name, :storage_name).new("AgentRun", "agent_run")
      Struct.new(:name, :aggregates).new("Hecks", [agent_run])
    end

    # A registry that booted the checkout root, with the bluebook's files below it.
    def checkout_registry(file = path)
      sources = ["#{home}/ledger_care/ledger_care.bluebook", "#{home}/hecks.bluebook"]
      allow(keeping::Ledger).to receive(:file_of).and_return(file)
      instance_double(Hecks::Runtime::Registry, root: "/checkout", bluebooks: { "Hecks" => bluebook },
                                                bluebook_sources: { "Hecks" => sources })
    end

    it "names the directory of the bluebook that declares AgentRun, not the registry's root" do
      expect(keeping::Ledger.directory(checkout_registry)).to eq(home)
    end

    it "names no directory when the records are not kept in a SQLite file" do
      expect(keeping::Ledger.directory(checkout_registry(nil))).to be_nil
    end
  end

  describe "a compaction the examination finds nothing for says why" do
    def abandoned(facts)
      registry = boot_hecks_in_memory(domain).registry
      journal = instance_double(Hecks::Adapters::JournalStore, examine: facts)
      lookup = ->(port, _asked) { port.to_s == "JournalStore" ? journal : nil }
      Hecks::Runtime::AdapterLookup.standing_in(lookup) { request_compaction(registry) }
      registry.event_log.find { |event| event.name == "SchemaRevisionAbandoned" }
    end

    def request_compaction(registry)
      Hecks::Runtime::Dispatcher.new(registry).dispatch_flat(
        "Hecks::SchemaRevision.Compact", domain: { value: "/checkout" }, run: { value: "care-1" }, confirm: { value: true }
      )
    end

    def facts(candidates:, bound: 0)
      { capable: false, held: 0, forks: 0, contested: 0, bound: bound, candidates: candidates,
        drifted: false, loadable: false, shape_kept: false, operation: "compact" }.transform_values { |fact| { value: fact } }
    end

    it "names the domain path and aggregates when no aggregate keeps a journal", :aggregate_failures do
      event = abandoned(facts(candidates: 0))

      expect(event.payload.to_s).to include("no aggregate in the domain keeps a journal to compact")
    end

    it "names the projection binding when one reads the journal" do
      event = abandoned(facts(candidates: 1, bound: 1))

      expect(event.payload.to_s).to include("a projected_by binding reads the journal")
    end
  end

  describe "the delivered outbox rows are purged on a beat" do
    def purge_beat(hours:)
      scratch_outbox(path, [["delivered", 30], ["pending", 30]])
      registry = boot_hecks_in_memory(domain).registry
      purging = purging_over(ledger_at(path), hours: hours)
      lookup = ->(port, _asked) { port.to_s == "Purging" ? purging : nil }
      Hecks::Runtime::AdapterLookup.standing_in(lookup) { beat(registry, false) }
      registry.event_log.map(&:name)
    end

    it "records the purge and asks for the vacuum", :aggregate_failures do
      names = purge_beat(hours: 24)

      expect(names).to include("OutboxPurged", "OutboxCareHeard", "ReclaimRequested")
      expect(outbox_counts(path)).to eq("pending" => 1)
    end

    it "only says why it waits when nothing is old enough", :aggregate_failures do
      names = purge_beat(hours: 100)

      expect(names).to include("OutboxHeld", "OutboxCareDeclined")
      expect(names).not_to include("ReclaimRequested")
    end
  end
end
