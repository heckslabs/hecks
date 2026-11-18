require "spec_helper"
require_relative "../../support/ledger_scratch"

# The upkeep of the AgentRun file: a beat weighs its journal against the world's line, a held
# file is deferred by name, and a vacuum gives the free pages back only when the file is quiet.
RSpec.describe Hecks::Adapters::LedgerKeeping do
  include LedgerScratch

  let(:failure) { Hecks::Adapters::ConsoleCapture::Failure }
  let(:path) { scratch_ledger(300) }

  after { FileUtils.rm_rf(File.dirname(path)) }

  describe "the line a beat compacts at" do
    it "counts the entries a compaction would delete" do
      expect(ledger_at(path).compactable).to eq(300)
    end

    it "is due over the line and names the compaction", :aggregate_failures do
      answer = weighing_over(ledger_at(path), entries: 299).weigh(run: { value: "beat-1" })

      expect(answer[:aggregates]).to eq(value: "AgentRun")
      expect(answer[:domain]).to eq(value: "/domains/hecks")
      expect(answer[:compaction]).to eq(value: "ledger-care-beat-1")
    end

    it "is deferred at the line, naming the count" do
      weighing = weighing_over(ledger_at(path), entries: 300)

      expect { weighing.weigh(run: "beat-1") }.to raise_error(failure, /300 entries are compactable, not over 300/)
    end

    it "counts only what is past the compaction floor" do
      SQLite3::Database.new(path).execute("UPDATE hecks_checkpoints SET compacted_through = 250")

      expect(ledger_at(path).compactable).to eq(50)
    end
  end

  describe "a file another process holds" do
    it "defers the beat by name and says the next beat tries again" do
      weighing = weighing_over(ledger_at(path), entries: 10)

      while_held(path) do
        expect { weighing.weigh(run: "beat-1") }.to raise_error(failure, /agent_run.db is held by another process.*next beat/)
      end
    end

    it "returns within the wait instead of waiting for the holder", :aggregate_failures do
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      while_held(path) { expect { ledger_at(path).compactable }.to raise_error(Hecks::Adapters::LedgerKeeping::Held) }
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 2
    end

    it "refuses the vacuum by name and leaves the file as it was", :aggregate_failures do
      reclaiming = Hecks::Adapters::LedgerReclaiming.new(registry: registry_over(ledger_at(path)))
      before = File.size(path)

      while_held(path) { expect { reclaiming.vacuum(run: "r") }.to raise_error(failure, /refused: agent_run.db is not quiet/) }
      expect(File.size(path)).to eq(before)
    end
  end

  describe "the delivered outbox rows" do
    let(:rows) { [["delivered", 30], ["delivered", 1], ["pending", 30], ["failed", 30], ["refused", 30]] }

    before { scratch_outbox(path, rows) }

    it "purges the delivered rows settled before the window and nothing else", :aggregate_failures do
      answer = purging_over(ledger_at(path), hours: 24).purge(run: { value: "beat-1" })

      expect(outbox_counts(path)).to eq("delivered" => 1, "pending" => 1, "failed" => 1, "refused" => 1)
      expect(answer[:reason][:value]).to include("1 delivered outbox rows older than 24 hours")
    end

    it "keeps a delivered row for the world's one hour, no longer", :aggregate_failures do
      recent = (Time.now.utc - 1800).iso8601
      SQLite3::Database.new(path).execute("UPDATE hecks_outbox SET settled_at = ? WHERE settled_at > ?", [recent, recent])

      expect(described_class::OutboxPurge.new(ledger_at(path)).purge!(hours: 1)).to eq(1)
      expect(outbox_counts(path)["delivered"]).to eq(1)
    end

    it "names the vacuum's run after the beat" do
      answer = purging_over(ledger_at(path), hours: 24).purge(run: "beat-1")

      expect(answer[:reclaim]).to eq(value: "outbox-care-beat-1")
    end

    it "is deferred when no delivered row is old enough" do
      purging = purging_over(ledger_at(path), hours: 100)

      expect { purging.purge(run: "beat-1") }.to raise_error(failure, /no delivered outbox rows are older than 100 hours/)
    end

    it "is deferred by name when another process holds the file" do
      purging = purging_over(ledger_at(path), hours: 24)

      while_held(path) { expect { purging.purge(run: "beat-1") }.to raise_error(failure, /held by another process/) }
    end

    it "stops at the batch cap and leaves the rest to the next beat" do
      stub_const("Hecks::Adapters::LedgerKeeping::OutboxPurge::BATCH", 1)
      stub_const("Hecks::Adapters::LedgerKeeping::OutboxPurge::BATCHES", 1)
      SQLite3::Database.new(path).execute("UPDATE hecks_outbox SET status = 'delivered', settled_at = '2020-01-01T00:00:00Z'")

      expect(described_class::OutboxPurge.new(ledger_at(path)).purge!(hours: 24)).to eq(1)
    end

    it "does nothing to a file without an outbox table" do
      SQLite3::Database.new(path).execute("DROP TABLE hecks_outbox")

      expect(described_class::OutboxPurge.new(ledger_at(path)).purge!(hours: 24)).to eq(0)
    end
  end

  describe "the vacuum" do
    def free_pages_after_compaction
      SQLite3::Database.new(path).tap { |db| db.execute("DELETE FROM agent_run_entries") }.close
    end

    it "gives the freed pages back and reports the size before and after", :aggregate_failures do
      free_pages_after_compaction
      sizes = ledger_at(path).vacuum!

      expect(sizes[:before]).to be > 100_000
      expect(sizes[:after]).to be < sizes[:before] / 4
    end

    it "leaves the remaining rows alone" do
      SQLite3::Database.new(path).execute("DELETE FROM agent_run_entries WHERE sequence <= 200")
      ledger_at(path).vacuum!

      expect(SQLite3::Database.new(path).get_first_value("SELECT COUNT(*) FROM agent_run_entries")).to eq(100)
    end
  end
end
