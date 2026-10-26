require "hecks"
require "tmpdir"
require_relative "../../support/persistence_adapter_examples"
require_relative "../../../lib/hecks/hecks/adapters/ledger"

# The Ledger port's adapter over a real Sqlite journal: what it seals, what a walk accepts, and
# what it refuses once a journal or a seal is altered.
RSpec.describe Hecks::Adapters::Ledger do
  include_context "with the Pizzas Order adapter helpers"

  around do |example|
    @dir = Dir.mktmpdir("hecks-ledger-")
    example.run
  ensure
    FileUtils.remove_entry(@dir) if @dir
  end

  before(:context) { @aggregate = boot_in_memory.registry.bluebook("Pizzas").aggregate("Order") }

  let(:aggregate) { @aggregate }
  let(:adapter) do
    Hecks::Adapters::Sqlite.new(aggregate: aggregate, settings: { database: "pizzas.db" }, root: @dir)
  end
  let(:ledger) { described_class.new }

  before { allow(ledger).to receive(:journals).and_return([Hecks::Adapters::Ledger::Journal.of(aggregate, adapter)]) }

  def chain = Hecks::Adapters::Ledger::Chain

  def domain = { domain: { value: "x" } }

  def wiring_error = Hecks::Runtime::WiringError

  def save_pizzas(*ids) = ids.each { |id| adapter.save(instance(id, status: "available")) }

  def seal = ledger.capture(**domain)

  def walk = ledger.walk(**domain)

  def seal_after_saving(*ids)
    save_pizzas(*ids)
    seal
  end

  def raw_db = adapter.instance_variable_get(:@db)

  def entry_table = adapter.send(:quoted_entry_table)

  def first_sequence = "(SELECT min(sequence) FROM #{entry_table})"

  describe "Chain" do
    let(:entries) { save_pizzas("p1", "p2") && adapter.entries }

    it "starts from sixty-four zeros" do
      expect(chain::GENESIS).to match(/\A0{64}\z/)
    end

    it "digests entries one after another" do
      step = chain.step(chain.step(chain::GENESIS, aggregate, entries[0]), aggregate, entries[1])
      expect(chain.fold(chain::GENESIS, aggregate, entries)).to eq(step)
    end

    it "digests the same entries in another order differently" do
      expect(chain.fold(chain::GENESIS, aggregate, entries.reverse)).not_to eq(chain.fold(chain::GENESIS, aggregate, entries))
    end

    it "does not depend on the order a summary lists its journals in" do
      points = [{ name: "a", through: 1, head: "x" }, { name: "b", through: 2, head: "y" }]
      expect(chain.summary(points, :head)).to eq(chain.summary(points.reverse, :head))
    end
  end

  describe "#capture" do
    it "refuses a domain whose journals hold no entries" do
      expect { seal }.to raise_error(wiring_error, /no journal entries/)
    end

    it "seals the journal through its checkpoint" do
      seal_after_saving("p1", "p2")
      expect(adapter.ledger_anchors.first).to include(through: adapter.checkpoint, previous: chain::GENESIS)
    end

    it "answers the sealed facts" do
      expect(seal_after_saving("p1", "p2")).to include(through: { value: adapter.checkpoint },
                                                       head:    { value: match(/\A[0-9a-f]{64}\z/) })
    end

    it "seals the same journal twice without adding a second seal" do
      seal_after_saving("p1")
      seal
      expect(adapter.ledger_anchors.size).to eq(1)
    end

    it "chains a later seal to the one before it" do
      2.times { |index| seal_after_saving("p#{index}") }
      first, second = adapter.ledger_anchors
      expect(second[:previous]).to eq(first[:head])
    end
  end

  describe "#walk" do
    it "is unproven when nothing is sealed" do
      save_pizzas("p1")
      expect { walk }.to raise_error(wiring_error, /nothing is sealed/)
    end

    it "accepts an untouched journal and counts what it re-walked" do
      seal_after_saving("p1", "p2")
      seal_after_saving("p3")
      expect(walk[:report][:value]).to include("2 seals held", "3 entries re-walked")
    end

    it "refuses a journal whose sealed entry was altered" do
      seal_after_saving("p1", "p2")
      raw_db.execute("UPDATE #{entry_table} SET operation = 'delete' WHERE sequence = #{first_sequence}")
      expect { walk }.to raise_error(wiring_error, /no longer matches the journal/)
    end

    it "refuses a journal with a sealed entry removed" do
      seal_after_saving("p1", "p2")
      raw_db.execute("DELETE FROM #{entry_table} WHERE sequence = #{first_sequence}")
      expect { walk }.to raise_error(wiring_error, /no longer matches the journal/)
    end

    it "still accepts a journal after a sealed compaction removed the sealed rows" do
      seal_after_saving("p1", "p2")
      adapter.compact_entries!(through: adapter.checkpoint)
      seal_after_saving("p3")
      expect(walk[:report][:value]).to include("2 seals held", "1 entries re-walked")
    end

    it "refuses a seal that does not follow the one before it" do
      2.times { |index| seal_after_saving("p#{index}") }
      raw_db.execute("UPDATE hecks_ledger_anchors SET previous = ? WHERE through_sequence = ?",
                     ["f" * 64, adapter.ledger_anchors.last[:through]])
      expect { walk }.to raise_error(wiring_error, /does not follow the seal before it/)
    end
  end

  describe "sealing a point twice with another head" do
    it "is refused, never overwritten" do
      adapter.record_ledger_anchor(through: 1, head: "a" * 64, previous: chain::GENESIS)
      expect { adapter.record_ledger_anchor(through: 1, head: "b" * 64, previous: chain::GENESIS) }
        .to raise_error(wiring_error, /already sealed/)
    end
  end
end
