require "tmpdir"
require "open3"
require "fileutils"

# bin/heki_compact is a SCRIPT, not a library — same reasoning
# bin_stores_spec.rb's own header gives: run it as a real subprocess
# (Open3) against real, on-disk fixture directories.
#
# Two fixtures, both real:
#   - spec/fixtures/heki_compact_fixture — one Heki-persisted aggregate
#     with NO `projected_by` binding at all, where compaction is
#     genuinely safe. Proves the actual behavior (dry run reports,
#     --force compacts, current state survives a fresh boot).
#   - examples/banking — a REAL, already-shipped example that pairs
#     `persisted_by("Heki")` with `projected_by("SqliteProjection")`.
#     Proves the refusal: compacting here would silently break
#     `Ports::Projection::Worker#catch_up!`/`Registry#
#     projection_current?`, both of which read an authoritative
#     adapter's `entries` in full, forever — confirmed directly (see
#     `Hecks::Adapters::Heki::Journal#compact!`'s own header) by
#     driving `Worker#catch_up!` against a compacted Heki store and
#     watching it raise `Runtime::WiringError` for real.
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
      # Heki's own `resolve_path` resolves relative to the BOOT ROOT
      # (`File.dirname` of the bluebook directory itself, per
      # `Runtime::Loader.boot`), not the bluebook directory — so the
      # store lands one level up from `bluebook_dir`, beside it, not
      # inside it.
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

      # Current state survives — a fresh boot after compaction sees
      # exactly what it did before.
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

      # The journal for a real Heki-backed banking aggregate is
      # untouched — nothing was compacted (and this spec never seeded
      # any data for it either, so it's never been written at all).
      journal_path = File.join(@dir, "data", "account.heki.journal")
      expect(File.exist?(journal_path)).to be false
    end
  end
end
