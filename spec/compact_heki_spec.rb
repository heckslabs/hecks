require "tmpdir"
require "fileutils"
require "hecks/hecks/adapters/journal_store/compaction"

# `hecks compact_heki` (Era.CompactHeki) through the compaction it runs, against on-disk
# fixtures: a Heki aggregate with no `projected_by` (safe to compact) and examples/banking
# (refused, since a projection worker reads the full journal).
RSpec.describe "hecks compact_heki" do
  HEKI_COMPACT_FIXTURE = File.join(InMemoryDomain::ROOT, "spec/fixtures/heki_compact_fixture/bluebook").freeze
  BANKING_FIXTURE = File.join(InMemoryDomain::ROOT, "examples/banking/bluebook").freeze

  around do |example|
    @dir = Dir.mktmpdir("hecks-heki-compact-spec-")
    example.run
  ensure
    FileUtils.remove_entry(@dir) if @dir
  end

  def copy_fixture(source, name)
    target = File.join(@dir, name)
    FileUtils.cp_r(source, target)
    target
  end

  def compaction(dir, *aggregates)
    Hecks::Adapters::JournalStore::Compaction.new(dir, aggregates: aggregates, kind: :heki)
  end

  def seed_gadget(bluebook_dir, writes: 5)
    runtime    = Hecks.boot(bluebook_dir, install_facade: false)
    registry   = runtime.registry
    aggregate  = registry.bluebook("HekiCompactFixture").aggregate("Gadget")
    repository = registry.repository("HekiCompactFixture", aggregate)

    writes.times do |i|
      built = Hecks::Runtime::Instance.new(aggregate: aggregate, id: "g1")
      built[:name]  = Hecks::Runtime::Value.for(aggregate, :name, { value: "g1" })
      built[:label] = Hecks::Runtime::Value.for(aggregate, :label, { value: "label#{i}" })
      repository.save(built)
    end
  end

  it "refuses a nonexistent domain path, naming it" do
    missing = File.join(@dir, "no-such-domain")

    expect { compaction(missing) }.to raise_error(Hecks::Runtime::NotFound, /#{Regexp.escape(missing)}/)
  end

  describe "against an aggregate nothing projects from" do
    it "dry-runs without touching the journal, then compacts for real once applied" do
      bluebook_dir = copy_fixture(HEKI_COMPACT_FIXTURE, "fixture")
      seed_gadget(bluebook_dir)
      # Heki resolves paths against the boot root (the bluebook directory's parent),
      # so the store lands beside `bluebook_dir`, not inside it.
      journal_path = File.join(@dir, "data", "gadget.heki.journal")
      expect(File.size(journal_path)).to be > 0

      expect(compaction(bluebook_dir).preview.join("\n")).to include("DRY RUN gadget")
      expect(File.size(journal_path)).to be > 0 # untouched by the dry run

      expect(compaction(bluebook_dir).apply!.join("\n")).to include("COMPACTED gadget")
      expect(File.size(journal_path)).to eq(0)

      runtime    = Hecks.boot(bluebook_dir, install_facade: false)
      aggregate  = runtime.registry.bluebook("HekiCompactFixture").aggregate("Gadget")
      repository = runtime.registry.repository("HekiCompactFixture", aggregate)
      expect(repository.find("g1")[:label].to_h).to eq(value: "label4")
      expect(repository.entries).to eq([])
    end

    it "skips a store whose journal is already empty" do
      bluebook_dir = copy_fixture(HEKI_COMPACT_FIXTURE, "fixture")
      seed_gadget(bluebook_dir, writes: 1)

      compaction(bluebook_dir).apply!
      lines = compaction(bluebook_dir).apply!

      expect(lines.join("\n")).to include("SKIP gadget: journal already empty")
    end
  end

  describe "against a real, live example that projects from Heki (examples/banking)" do
    it "refuses every projected aggregate outright, even when applied" do
      bluebook_dir = copy_fixture(BANKING_FIXTURE, "banking")

      expect { compaction(bluebook_dir).apply! }.to raise_error(Hecks::Runtime::WiringError) do |error|
        %w[customer account transfer].each do |storage_name|
          expect(error.message).to include("REFUSED #{storage_name}")
          expect(error.message).to include("projected_by binding")
        end
      end

      # Nothing was compacted; this spec never seeds banking data, so no journal exists.
      journal_path = File.join(@dir, "data", "account.heki.journal")
      expect(File.exist?(journal_path)).to be false
    end
  end
end
