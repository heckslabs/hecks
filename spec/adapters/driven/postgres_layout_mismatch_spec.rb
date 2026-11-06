require "hecks"
require "hecks/ports/persistence/plugins/era"
require_relative "../../support/postgres_probe"
require_relative "../../support/scratch_postgres"
require_relative "../../support/fenced_owner"
require_relative "../../support/era_registry_loading"
require_relative "../../support/first_era_hold"

# A database keeps one layout for a domain (ADR 0182): a plain Postgres binding refuses a database
# that already holds the domain's eras, and a `revisions true` binding refuses one that holds none.
RSpec.describe "Postgres layout mismatch", :io do
  include EraRegistryLoading
  include FirstEraHold

  LAYOUT_DB = "hecks_layout_mismatch_spec".freeze

  scratch_postgres LAYOUT_DB, fenced: true

  def layout_url = FencedOwner.url(LAYOUT_DB)

  def source
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

  def aggregate = load_registry(source).bluebooks.values.first.aggregate("Acct")

  def bind(**extra)
    settings = { database: layout_url, domain: "Ledger" }.merge(extra)
    Hecks::Adapters::Postgres.new(aggregate: aggregate, settings: settings)
  end

  def tables
    db = PG.connect(layout_url)
    db.exec("SELECT tablename FROM pg_tables WHERE schemaname = current_schema()").map { |r| r["tablename"] }
  ensure
    db&.close
  end

  context "when the database holds the domain's era" do
    before { hold_first_era!(url: layout_url, domain: "Ledger", source: source) }

    it "refuses a plain binding, naming `revisions true`" do
      expect { bind }.to raise_error(Hecks::Runtime::WiringError, /revisions true/)
    end
  end

  context "when the database is empty" do
    before { bind }

    it "keeps the table layout", :aggregate_failures do
      expect(tables).to include("acct")
      expect(tables).not_to include("hecks_eras")
    end
  end

  context "when the database keeps the table layout" do
    before { bind }

    it "refuses a `revisions true` binding, as no era is held" do
      expect { bind(revisions: true) }.to raise_error(Hecks::Runtime::WiringError, /no era held/)
    end
  end
end
