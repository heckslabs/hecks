require "hecks"
require "hecks/ports/persistence/plugins/era"
require "json"
require "tmpdir"
require_relative "../../../support/postgres_probe"
require_relative "../../../support/scratch_postgres"
require_relative "../../../support/fenced_owner"
require_relative "../../../support/era_registry_loading"
require_relative "../../../../lib/hecks/hecks/adapters/journal_store"

# The label of a held era comes from its stored hash or its projection, never from a decision about
# its held text: a resolution and the boot status answer a label and a status for an era holding
# the root file beside a projection, and for an era holding whole text and no projection.
RSpec.describe "the label a resolution gives a held era", :io do
  include EraRegistryLoading

  LABEL_DB = "hecks_held_label_resolution_spec".freeze

  scratch_postgres LABEL_DB, fenced: true

  def url = FencedOwner.url(LABEL_DB)

  def full_source
    <<~BLUEBOOK
      Hecks.bluebook "Ledger" do
        aggregate "Acct" do
          identified_by :kind

          attribute :kind, Kind

          value_object "Kind" do
            attribute :label, String
          end
        end
      end
    BLUEBOOK
  end

  def root_source = %(Hecks.bluebook "Ledger" do\nend\n)

  def full_bluebook = load_registry(full_source).bluebooks.values.first

  def full_hash = Hecks::Runtime::StorageShape.mint_hash(full_bluebook)

  def hold!(text, projection, named: false)
    db = Hecks::Adapters::PostgresRevisions.connect_for("Ledger", { database: url })
    lineage = Hecks::Adapters::PostgresRevisions::Lineage.new(db, "Ledger")
    lineage.ensure_base!
    lineage.hold_first!(text, projection: projection)
    lineage.mint_name!(1, full_hash, full_hash[0, 6]) if named
    lineage.provision_first_era!(full_bluebook.aggregates)
  ensure
    db&.close
  end

  def resolution
    Hecks::Adapters::PostgresRevisions::LineageManager::RevisionResolution.read(
      bluebook: full_bluebook, settings: { database: url }, translations: []
    )
  end

  def write_domain(dir)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "ledger.bluebook"), full_source)
    File.write(File.join(dir, "shapes.json"), JSON.generate("Ledger" => full_hash))
    File.write(File.join(dir, "ledger.hecksagon"), %(Hecks.hecksagon "Ledger" do\n  persisted_by "Postgres"
  revisions true\nend\n))
    File.write(File.join(dir, "ledger.world"),
               %(Hecks.world "Ledger" do\n  persisted_by("Postgres") do\n    database "#{url}"\n  end\nend\n))
  end

  def status_row
    Dir.mktmpdir do |root|
      dir = File.join(root, "bluebook")
      write_domain(dir)
      JSON.parse(Hecks::Adapters::JournalStore.new.boot_status(domain: dir)[:text])["bluebooks"]["Ledger"]
    end
  end

  context "with an unnamed era holding the root file and the whole domain's projection" do
    before { hold!(root_source, Hecks::Runtime::StorageShape.project(full_bluebook)) }

    it "labels the era from its projection and resolves it current", :aggregate_failures do
      answer = resolution
      expect(answer.status).to eq("current")
      expect(answer.held_label).to eq(full_hash[0, 6])
    end

    it "answers the boot status row without raising", :aggregate_failures do
      row = status_row
      expect(row["status"]).to eq("current")
      expect(row["held"]).to eq(full_hash[0, 6])
    end
  end

  context "with a named era holding whole text and no projection" do
    before { hold!(full_source, nil, named: true) }

    it "labels the era from its stored name", :aggregate_failures do
      answer = resolution
      expect(answer.status).to eq("current")
      expect(answer.held_label).to eq(full_hash[0, 6])
    end

    it "answers the boot status row without raising" do
      expect(status_row.values_at("status", "held")).to eq(["current", full_hash[0, 6]])
    end
  end

  context "with an unnamed era holding no projection" do
    before { hold!(full_source, nil) }

    it "refuses the era by name" do
      expect { resolution }.to raise_error(Hecks::Runtime::WiringError, /era 1 .* stores no storage shape/)
    end
  end
end
