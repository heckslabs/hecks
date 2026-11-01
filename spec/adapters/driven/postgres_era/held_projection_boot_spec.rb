require "hecks"
require "hecks/ports/persistence/plugins/era"
require_relative "../../../support/postgres_probe"
require_relative "../../../support/scratch_postgres"
require_relative "../../../support/fenced_owner"
require_relative "../../../support/era_registry_loading"

# How a boot matches its shape against a held era of a domain split across files: the held text is
# the root file only, so the boot compares the projection the mint recorded, and falls back to the
# held text's own shape for an era minted without one.
RSpec.describe "a boot matching a held era by its recorded projection", :io do
  include EraRegistryLoading

  PROJECTION_DB = "hecks_held_projection_boot_spec".freeze

  scratch_postgres PROJECTION_DB, fenced: true

  def boot_url = FencedOwner.url(PROJECTION_DB)

  # The whole domain as the checkout declares it.
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

  # The root file of a domain whose aggregates live in other files: it declares none of them.
  def root_source = %(Hecks.bluebook "Ledger" do\nend\n)

  def projection_of(source) = Hecks::Runtime::StorageShape.project(load_registry(source).bluebooks.values.first)

  # Holds era 1 with `text` as its held text and `projection` as the shape its mint recorded.
  def hold!(text, projection)
    db = Hecks::Adapters::PostgresEra.connect_for("Ledger", { database: boot_url })
    lineage = Hecks::Adapters::PostgresEra::Lineage.new(db, "Ledger")
    lineage.ensure_base!
    lineage.hold_first!(text, projection: projection)
    lineage.provision_first_era!(load_registry(full_source).bluebooks.values.first.aggregates)
  ensure
    db&.close
  end

  # Boots the era check of the full domain against the database, without a mint request.
  def boot
    registry = load_registry(full_source)
    Hecks::Adapters::PostgresEra::LineageManager.check!(
      registry: registry, bluebook: registry.bluebooks.values.first, current_text: full_source,
      settings: { database: boot_url, mint_eras: true }
    )
    registry
  end

  context "with an era holding the root file and the whole domain's projection" do
    before { hold!(root_source, projection_of(full_source)) }

    it "resolves the boot to the held era", :aggregate_failures do
      registry = boot
      expect(registry.resolved_eras["Ledger"]).to eq(1)
      expect(registry.unminted_eras["Ledger"]).to be_nil
    end
  end

  context "with an era holding the whole domain's text and no projection" do
    before { hold!(full_source, nil) }

    it "resolves the boot to the held era by the shape its text declares" do
      expect(boot.unminted_eras["Ledger"]).to be_nil
    end
  end

  context "with an era holding the root file and no projection" do
    before { hold!(root_source, nil) }

    it "boots unminted, since the text alone declares none of the domain's aggregates" do
      expect(boot.unminted_eras["Ledger"]).to eq(1)
    end
  end
end
