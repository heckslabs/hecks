require "tmpdir"
require "open3"
require "fileutils"

# Runs bin/heki_compact as a subprocess (Open3) against on-disk fixtures: a Heki
# aggregate with no `projected_by` (safe to compact) and examples/banking (refused,
# since a projection worker reads the full journal).
RSpec.describe "bin/heki_compact" do
  HEKI_COMPACT_SCRIPT = File.join(InMemoryDomain::ROOT, "bin/heki_compact").freeze
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

  it "requires a domain argument at all" do
    _stdout, _stderr, status = Open3.capture3(HEKI_COMPACT_SCRIPT)

    expect(status).not_to be_success
  end

  it "exits non-zero with a clear message for a nonexistent domain path" do
    missing = File.join(@dir, "no-such-domain")

    stdout, stderr, status = Open3.capture3(HEKI_COMPACT_SCRIPT, missing)

    expect(status).not_to be_success
    expect(stdout).to eq("")
    expect(stderr).to include(missing)
  end

  describe "against an aggregate nothing projects from" do
    it "dry-runs without touching the journal, then compacts for real under --force" do
      bluebook_dir = copy_fixture(HEKI_COMPACT_FIXTURE, "fixture")
      seed_gadget(bluebook_dir)
      # Heki resolves paths against the boot root (the bluebook directory's parent),
      # so the store lands beside `bluebook_dir`, not inside it.
      journal_path = File.join(@dir, "data", "gadget.heki.journal")
      expect(File.size(journal_path)).to be > 0

      dry_stdout, _stderr, dry_status = Open3.capture3(HEKI_COMPACT_SCRIPT, bluebook_dir)
      expect(dry_status).to be_success
      expect(dry_stdout).to include("DRY RUN gadget")
      expect(dry_stdout).to include("Re-run with --force")
      expect(File.size(journal_path)).to be > 0 # untouched by the dry run

      force_stdout, _stderr, force_status = Open3.capture3(HEKI_COMPACT_SCRIPT, bluebook_dir, "--force")
      expect(force_status).to be_success
      expect(force_stdout).to include("COMPACTED gadget")
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

      Open3.capture3(HEKI_COMPACT_SCRIPT, bluebook_dir, "--force")
      stdout, _stderr, status = Open3.capture3(HEKI_COMPACT_SCRIPT, bluebook_dir, "--force")

      expect(status).to be_success
      expect(stdout).to include("SKIP gadget: journal already empty")
    end
  end

  describe "against a real, live example that projects from Heki (examples/banking)" do
    it "refuses every projected aggregate outright, even with --force, and exits non-zero" do
      bluebook_dir = copy_fixture(BANKING_FIXTURE, "banking")

      stdout, stderr, status = Open3.capture3(HEKI_COMPACT_SCRIPT, bluebook_dir, "--force")

      expect(status).not_to be_success
      expect(stdout).to eq("")
      %w[customer account transfer].each do |storage_name|
        expect(stderr).to include("REFUSED #{storage_name}")
        expect(stderr).to include("projected_by binding")
      end

      # Nothing was compacted; this spec never seeds banking data, so no journal exists.
      journal_path = File.join(@dir, "data", "account.heki.journal")
      expect(File.exist?(journal_path)).to be false
    end
  end
end
