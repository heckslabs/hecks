require "hecks"
require "tmpdir"
require "hecks/ports/persistence/plugins/era"
require_relative "../../../support/postgres_probe"
require_relative "../../../support/scratch_postgres"
require_relative "../../../support/fenced_owner"

# A domain split into module folders, held as an era and read back: the held text, kept for audit,
# is every file the loader reads, the top-level file and each module folder's, so it hashes to the
# shape the era's mint recorded.
RSpec.describe "an era held from a domain split into module folders", :io do
  MODULE_FOLDER_DB = "hecks_module_folder_held_text_spec".freeze

  scratch_postgres MODULE_FOLDER_DB, fenced: true

  def url = FencedOwner.url(MODULE_FOLDER_DB)

  def manager = Hecks::Adapters::PostgresEra::LineageManager

  TOP_LEVEL = %(Hecks.bluebook "Ledger" do\n  vision "Keep accounts."\nend\n).freeze

  BOOKS = <<~BLUEBOOK.freeze
    Hecks.bluebook "Ledger" do
      domain_module "Books" do
        vision "The accounts."

        aggregate "Acct" do
          identified_by :kind

          attribute :kind, Kind

          value_object "Kind" do
            attribute :label, String
          end
        end
      end
    end
  BLUEBOOK

  # Writes the domain, its top-level file and its Books module folder, into a scratch directory.
  def write_domain(dir)
    File.write(File.join(dir, "ledger.bluebook"), TOP_LEVEL)
    FileUtils.mkdir_p(File.join(dir, "books"))
    File.write(File.join(dir, "books", "books.bluebook"), BOOKS)
  end

  # Holds era 1 from the domain's source as the era check reads it, and answers that era.
  def held_era
    Dir.mktmpdir do |dir|
      write_domain(dir)
      bluebook = Hecks.describe(dir).registry.bluebooks["Ledger"]
      hold!(Hecks::Runtime::EraCheck.source_text_for(bluebook, dir), bluebook)
    end
  end

  def hold!(text, bluebook)
    db = Hecks::Adapters::PostgresEra.connect_for("Ledger", { database: url })
    lineage = Hecks::Adapters::PostgresEra::Lineage.new(db, "Ledger")
    lineage.ensure_base!
    lineage.hold_first!(text, projection: Hecks::Runtime::StorageShape.project(bluebook))
    lineage.eras.last
  ensure
    db&.close
  end

  it "holds every file the loader reads, the module folder's included" do
    expect(held_era[:held_text]).to include(%(domain_module "Books"))
  end

  it "answers the held era's aggregates, the module folder's included, from its stored shape" do
    expect(manager.held_bluebook(held_era).aggregates.map(&:name)).to eq(["Acct"])
  end

  it "holds a text that hashes to the shape its mint recorded, so it can stand in for a missing one" do
    era = held_era
    named = era.merge(projection: nil, hash: Hecks::Runtime::ProjectedBluebook.new(era[:projection]).mint_hash)
    expect(manager.verified_text_shape(named)).to eq(era[:projection])
  end
end
