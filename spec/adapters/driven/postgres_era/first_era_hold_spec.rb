require "hecks"
require "hecks/ports/persistence/plugins/era"
require_relative "../../../support/postgres_probe"
require_relative "../../../support/scratch_postgres"
require_relative "../../../support/fenced_owner"
require_relative "../../../support/era_registry_loading"
require_relative "../../../support/era_app_role"

# The first-era hold is one transaction, completes when a half-done run is repeated, and grants an
# app role only when the world names one.
RSpec.describe "PostgresRevisions first-era hold", :io do
  include EraRegistryLoading
  include EraAppRole

  HOLD_DB = "hecks_first_era_hold_spec".freeze
  HOLD_ROLE = "hecks_first_era_hold_spec_app".freeze
  HOLD_SOURCE = <<~BLUEBOOK.freeze
    Hecks.bluebook "Holdable" do
      aggregate "Thing" do
        identified_by :tag
        attribute :tag, Tag

        value_object "Tag" do
          attribute :value, String
        end
      end
    end
  BLUEBOOK

  scratch_postgres HOLD_DB, fenced: true

  def app_role_database = HOLD_DB
  def app_role_name = HOLD_ROLE

  def bluebook = @bluebook ||= load_registry(HOLD_SOURCE).bluebooks.values.first

  def projection = Hecks::Runtime::StorageShape.project(bluebook)

  def lineage
    @db ||= Hecks::Adapters::PostgresRevisions.connect_for("Holdable", { database: FencedOwner.url(HOLD_DB) })
    @lineage ||= Hecks::Adapters::PostgresRevisions::Lineage.new(@db, "Holdable").tap(&:ensure_base!)
  end

  after { @db&.close }

  def hold!(role: nil)
    lineage.hold_first_era!(HOLD_SOURCE, projection: projection, aggregates: bluebook.aggregates, role: role)
  end

  def head_present?
    lineage.table_exists?(lineage.head_view("thing"))
  end

  describe "the role" do
    it "grants nothing for an empty role" do
      expect { lineage.provision_first_era!(bluebook.aggregates, role: "") }.not_to raise_error
    end

    it "grants nothing for a nil role" do
      expect { lineage.grant_role!(nil, aggregates: bluebook.aggregates, era: 1) }.not_to raise_error
    end

    it "grants a named role, quoted", :aggregate_failures do
      reset_app_role!
      hold!(role: HOLD_ROLE)
      expect(as_app_role("SELECT count(*) FROM #{lineage.quoted_journal}")).to eq(:allowed)
    end
  end

  describe "a hold" do
    it "holds era 1 and its read side together", :aggregate_failures do
      hold!
      expect(lineage.eras.map { |era| era[:ordinal] }).to eq([1])
      expect(head_present?).to be(true)
    end

    it "leaves nothing behind when provisioning fails", :aggregate_failures do
      allow(lineage).to receive(:provision_read_side!).and_raise(PG::Error, "boom")
      expect { hold! }.to raise_error(PG::Error, "boom")
      expect(lineage.eras).to be_empty
    end

    it "completes a half-done run when repeated", :aggregate_failures do
      lineage.hold_first!(HOLD_SOURCE, projection: projection)
      hold!
      expect(head_present?).to be(true)
      expect(lineage.eras.size).to eq(1)
    end

    it "refuses a second hold of a finished one" do
      hold!
      expect { hold! }.to raise_error(Hecks::Runtime::WiringError, /already holds an era/)
    end

    it "refuses an era held from other text" do
      lineage.hold_first!("#{HOLD_SOURCE}# other\n", projection: projection)
      expect { hold! }.to raise_error(Hecks::Runtime::WiringError, /already holds an era/)
    end
  end
end
