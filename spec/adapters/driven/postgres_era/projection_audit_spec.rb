require "hecks"
require "hecks/ports/persistence/plugins/era"
require "json"
require "tmpdir"
require_relative "../../../support/postgres_probe"
require_relative "../../../support/scratch_postgres"
require_relative "../../../support/fenced_owner"
require_relative "../../../support/era_registry_loading"
require_relative "../../../support/first_era_hold"
require_relative "../../../../lib/hecks/hecks/adapters/journal_store"

# `Era.ProjectionAudit` recomputes the hash of each era's stored projection and compares it with
# the era's stored hash; the boot resolution marks an era where they disagree with a warning, and
# still resolves. Both only read.
RSpec.describe "the stored projection checked against the era's hash", :io do
  include EraRegistryLoading
  include FirstEraHold

  AUDIT_DB = "hecks_projection_audit_spec".freeze

  scratch_postgres AUDIT_DB, fenced: true

  def url = FencedOwner.url(AUDIT_DB)

  def source(field)
    <<~BLUEBOOK
      Hecks.bluebook "Audited" do
        aggregate "Acct" do
          identified_by :kind

          attribute :#{field}, Money
          attribute :kind, Kind

          value_object "Money" do
            attribute :cents, Integer
          end

          value_object "Kind" do
            attribute :label, String
          end
        end
      end
    BLUEBOOK
  end

  def projection_of(text) = Hecks::Runtime::StorageShape.project(load_registry(text).bluebooks.values.first)

  # Holds era 1 and names it, as a mint leaving it would.
  def hold_named_era!
    hold_first_era!(url: url, domain: "Audited", source: source("cost"))
    db = Hecks::Adapters::PostgresRevision.connect_for("Audited", { database: url })
    lineage = Hecks::Adapters::PostgresRevision::Lineage.new(db, "Audited")
    Hecks::Adapters::PostgresRevision::LineageManager.ensure_named!(lineage, lineage.eras.first)
  ensure
    db&.close
  end

  # Stores another shape's projection under era 1, leaving its hash as it was.
  def swap_projection!
    db = PG.connect(url)
    db.exec_params("UPDATE hecks_eras SET held_projection = $1::jsonb WHERE domain = 'Audited'",
                   [JSON.generate(projection_of(source("amount")))])
  ensure
    db&.close
  end

  def with_domain
    Dir.mktmpdir do |root|
      dir = File.join(root, "bluebook")
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, "audited.bluebook"), source("cost"))
      File.write(File.join(dir, "audited.hecksagon"), %(Hecks.hecksagon "Audited" do\n  persisted_by "Postgres"
  revisions true\nend\n))
      File.write(File.join(dir, "audited.world"),
                 %(Hecks.world "Audited" do\n  persisted_by("Postgres") do\n    database "#{url}"\n  end\nend\n))
      yield dir
    end
  end

  def audit(dir) = JSON.parse(Hecks::Adapters::JournalStore.new.projection_audit(domain: dir)[:text])

  def resolution(dir)
    JSON.parse(Hecks::Adapters::JournalStore.new.boot_resolution(domain: dir)[:text])["bluebooks"]["Audited"]
  end

  before { hold_named_era! }

  it "reports nothing for an era whose projection hashes to its hash", :aggregate_failures do
    with_domain do |dir|
      expect(audit(dir)["mismatches"]).to be_empty
      expect(resolution(dir)).not_to have_key("warning")
    end
  end

  it "reports the era whose projection hashes to another value" do
    swap_projection!
    with_domain do |dir|
      expect(audit(dir)["mismatches"].map { |row| row.values_at("domain", "ordinal") }).to eq([["Audited", 1]])
    end
  end

  # The first mismatch the audit reports after the projection is swapped.
  def swapped_mismatch
    swap_projection!
    with_domain { |dir| audit(dir)["mismatches"].first }
  end

  it "reports the recomputed hash" do
    expected = Hecks::Runtime::ProjectedBluebook.new(projection_of(source("amount"))).mint_hash
    expect(swapped_mismatch["recomputed"]).to eq(expected)
  end

  it "reports a stored hash that differs from it" do
    expect(swapped_mismatch.values_at("stored", "recomputed").uniq.size).to eq(2)
  end

  it "marks the boot resolution with a warning" do
    swap_projection!
    with_domain do |dir|
      expect(resolution(dir)["warning"]).to match(/era 1 stores hash \h{6} but its stored projection hashes to \h{6}/)
    end
  end

  it "still resolves a status for the marked era" do
    swap_projection!
    with_domain { |dir| expect(resolution(dir)["status"]).not_to be_nil }
  end

  it "writes no era row", :aggregate_failures do
    swap_projection!
    before = PG.connect(url).exec("SELECT * FROM hecks_eras").values
    with_domain { |dir| [audit(dir), resolution(dir)] }
    expect(PG.connect(url).exec("SELECT * FROM hecks_eras").values).to eq(before)
  end
end
