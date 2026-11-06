require "hecks"
require "hecks/ports/persistence/plugins/era"
require_relative "../../../support/postgres_probe"
require_relative "../../../support/scratch_postgres"
require_relative "../../../support/fenced_owner"
require_relative "../../../support/era_registry_loading"
require_relative "../../../support/mint_request_support"

# The mint guards of PostgresRevision's era check, on a disposable database: a boot never mints,
# and a
# mint needs a confirmed would_mint rehearsal at the watermark it read. Each refusal names why.
RSpec.describe "mint guards in the PostgresRevision era check", :io do
  include EraRegistryLoading
  include MintRequestSupport

  GUARD_DB = "hecks_mint_guards_spec".freeze

  scratch_postgres GUARD_DB, fenced: true

  def guard_url = FencedOwner.url(GUARD_DB)

  def shape_v1 = shape("cost")

  def shape_v2 = shape("amount")

  # One aggregate whose first attribute is `field`; its types are value objects.
  def shape(field)
    <<~BLUEBOOK
      Hecks.bluebook "Ledger" do
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

  def label_of(source)
    hash = Hecks::Runtime::StorageShape.mint_hash(load_registry(source).bluebooks.values.first)
    hash[0, 6]
  end

  def edge_v1_to_v2
    <<~RUBY
      Hecks.data_translation("Ledger", from: #{label_of(shape_v1).inspect},
                             to: #{label_of(shape_v2).inspect}) do
        aggregate("Acct") do
          rename :cost, to: :amount
        end
      end
    RUBY
  end

  # Checks the source against the database, with `settings` added to a copy that owns it.
  def check!(source, translation_source: nil, settings: {})
    registry = load_registry(source, translation_source: translation_source)
    base = { database: guard_url, mint_eras: true }
    Hecks::Adapters::PostgresRevision::LineageManager.check!(
      registry: registry, bluebook: registry.bluebooks.values.first, current_text: source,
      settings: base.merge(settings)
    )
    registry
  end

  # The settings carrying the mint command's request; the watermark defaults to the database's now.
  def mint_request_for(verdict: "would_mint", confirm: true, watermark: nil)
    watermark ||= watermark_of(guard_url, "Ledger")
    { mint_request: { confirm: confirm, verdict: verdict, watermark: watermark } }
  end

  # Holds the first era the way the `hold_first` command does: a boot never holds one.
  def hold_first!(source)
    registry = load_registry(source)
    bluebook = registry.bluebooks.values.first
    db = Hecks::Adapters::PostgresRevision.connect_for("Ledger", { database: guard_url })
    lineage = Hecks::Adapters::PostgresRevision::Lineage.new(db, "Ledger")
    lineage.ensure_base!
    lineage.hold_first!(source, projection: Hecks::Runtime::StorageShape.project(bluebook))
    bluebook.aggregates.each { |aggregate| lineage.ensure_first_head!(aggregate.storage_name) }
  ensure
    db&.close
  end

  def era_count
    connection = PG.connect(guard_url)
    connection.exec("SELECT count(*) AS n FROM hecks_eras WHERE domain = 'Ledger'")[0]["n"].to_i
  ensure
    connection&.close
  end

  before { hold_first!(shape_v1) }

  it "a boot still refuses to mint, and a read still works without minting", :aggregate_failures do
    registry = check!(shape_v2, translation_source: edge_v1_to_v2)
    expect(era_count).to eq(1)
    expect(registry.resolved_eras["Ledger"]).to eq(1)
  end

  it "refuses a mint that was not confirmed", :aggregate_failures do
    settings = mint_request_for(confirm: false)
    expect { check!(shape_v2, translation_source: edge_v1_to_v2, settings: settings) }
      .to raise_error(Hecks::Runtime::WiringError, /cannot mint era 2 of Ledger: the mint was not confirmed/)
    expect(era_count).to eq(1)
  end

  it "refuses a mint whose rehearsal did not say would_mint, by name" do
    settings = mint_request_for(verdict: "would_refuse")
    expect { check!(shape_v2, translation_source: edge_v1_to_v2, settings: settings) }
      .to raise_error(Hecks::Runtime::WiringError, /rehearsal's verdict was would_refuse, not would_mint/)
  end

  it "refuses a mint whose watermark moved since the rehearsal, by name" do
    settings = mint_request_for(watermark: 99)
    expect { check!(shape_v2, translation_source: edge_v1_to_v2, settings: settings) }
      .to raise_error(Hecks::Runtime::WiringError, /ledger watermark moved from 99 to \d+ since the rehearsal/)
  end

  it "refuses a mint from a copy whose world does not allow minting", :aggregate_failures do
    settings = mint_request_for.merge(mint_eras: false)
    expect { check!(shape_v2, translation_source: edge_v1_to_v2, settings: settings) }
      .to raise_error(Hecks::Runtime::WiringError, /may not mint/)
    expect(era_count).to eq(1)
  end

  it "mints when the rehearsal said would_mint at the watermark the database holds", :aggregate_failures do
    check!(shape_v2, translation_source: edge_v1_to_v2, settings: mint_request_for)
    expect(era_count).to eq(2)
  end
end
