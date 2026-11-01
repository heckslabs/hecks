require "hecks"
require "hecks/ports/persistence/plugins/era"
require_relative "../../../support/postgres_probe"
require_relative "../../../support/scratch_postgres"
require_relative "../../../support/fenced_owner"
require_relative "../../../support/era_registry_loading"
require_relative "../../../support/mint_request_support"

# A mint from an era whose held text is the top-level file of a domain split into module folders,
# with the hand-written edge a rename needs: the decision, the coverage check and the era's name all
# read the storage shape the era's mint recorded, so the edge the decision takes is the edge the
# mint applies.
RSpec.describe "a mint by a written edge from an era whose held text is partial", :io do
  include EraRegistryLoading
  include MintRequestSupport

  PARTIAL_TEXT_DB = "hecks_partial_text_edge_mint_spec".freeze

  scratch_postgres PARTIAL_TEXT_DB, fenced: true

  def url = FencedOwner.url(PARTIAL_TEXT_DB)

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

  def label_of(source) = Hecks::Runtime::StorageShape.mint_label(load_registry(source).bluebooks.values.first)

  def edge
    <<~RUBY
      Hecks.data_translation("Ledger", from: #{label_of(shape("cost")).inspect}, to: #{label_of(shape("amount")).inspect}) do
        aggregate("Acct") do
          rename :cost, to: :amount
        end
      end
    RUBY
  end

  # Holds era 1 with only the top-level file as its held text and the whole domain's shape.
  def hold_partial!
    bluebook = load_registry(shape("cost")).bluebooks.values.first
    db = Hecks::Adapters::PostgresEra.connect_for("Ledger", { database: url })
    lineage = Hecks::Adapters::PostgresEra::Lineage.new(db, "Ledger")
    lineage.ensure_base!
    lineage.hold_first!(%(Hecks.bluebook "Ledger" do\nend\n), projection: Hecks::Runtime::StorageShape.project(bluebook))
    lineage.provision_first_era!(bluebook.aggregates)
  ensure
    db&.close
  end

  def mint_registry
    registry = load_registry(shape("amount"), translation_source: edge)
    request = { confirm: true, verdict: "would_mint", watermark: watermark_of(url, "Ledger") }
    Hecks::Adapters::PostgresEra::LineageManager.check!(
      registry: registry, bluebook: registry.bluebooks.values.first, current_text: shape("amount"),
      settings: { database: url, mint_eras: true, mint_request: request }
    )
    registry
  end

  before { hold_partial! }

  it "mints the next era by the written edge" do
    expect(mint_registry.resolved_eras["Ledger"]).to eq(2)
  end
end
