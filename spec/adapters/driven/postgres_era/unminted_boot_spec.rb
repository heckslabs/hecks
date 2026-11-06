require "hecks"
require "hecks/ports/persistence/plugins/era"
require_relative "../../../support/postgres_probe"
require_relative "../../../support/scratch_postgres"
require_relative "../../../support/fenced_owner"
require_relative "../../../support/era_registry_loading"
require_relative "../../../support/mint_request_support"
require_relative "../../../support/first_era_hold"

# What a boot may do with its journal when its shape is unminted, superseded, or the mint's own
# boot: an unminted boot reads and refuses writes by naming the mint entry point, a superseded
# boot refuses by naming its superseding era, and a mint boot carrying its request writes.
RSpec.describe "unminted and superseded boots in PostgresRevision", :io do
  include EraRegistryLoading
  include MintRequestSupport
  include FirstEraHold

  BOOT_DB = "hecks_unminted_boot_spec".freeze

  scratch_postgres BOOT_DB, fenced: true

  def boot_url = FencedOwner.url(BOOT_DB)

  def shape_v1 = shape("cost")

  def shape_v2 = shape("amount")

  # Held by no era in these examples: booted with no mint request, it is unminted.
  def shape_v3 = shape("total")

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
    Hecks::Runtime::StorageShape.mint_hash(load_registry(source).bluebooks.values.first)[0, 6]
  end

  def edge_v1_to_v2 = edge(shape_v2, :amount)

  # The edge a breaking move needs to boot at all: a boot over one no edge covers refuses.
  def edge_v1_to_v3 = edge(shape_v3, :total)

  def edge(target, renamed)
    <<~RUBY
      Hecks.data_translation("Ledger", from: #{label_of(shape_v1).inspect},
                             to: #{label_of(target).inspect}) do
        aggregate("Acct") do
          rename :cost, to: #{renamed.inspect}
        end
      end
    RUBY
  end

  # Boots the era check of `source` against the database, with `settings` added to a copy that
  # owns it.
  def registry_for(source, translation_source: nil, settings: {})
    registry = load_registry(source, translation_source: translation_source)
    Hecks::Adapters::PostgresRevision::LineageManager.check!(
      registry: registry, bluebook: registry.bluebooks.values.first, current_text: source,
      settings: { database: boot_url, mint_eras: true }.merge(settings)
    )
    registry
  end

  # The settings the mint command's request adds: a confirmed would_mint at the watermark held now.
  def mint_request_settings
    { mint_request: { confirm: true, verdict: "would_mint", watermark: watermark_of(boot_url, "Ledger") } }
  end

  # The adapter a boot builds from `registry`, with the settings RepositoryFactory.build merges in.
  def adapter_for(registry, era:, **flags)
    settings = { database: boot_url, domain: "Ledger", era: era }.merge(flags)
    Hecks::Adapters::PostgresRevision.new(aggregate: registry.bluebooks.values.first.aggregate("Acct"),
                                          settings:  settings)
  end

  def entry
    Hecks::Ports::Persistence::Entry.new(operation: "save", id: "acct-1",
                                         state: { amount: { "cents" => 5 }, kind: { "label" => "biz" } },
                                         mirrors: nil)
  end

  # The refusal message of a write, or nil when the write went through.
  def write_error(adapter)
    adapter.append(entry)
    nil
  rescue Hecks::Runtime::WiringError => e
    e.message
  end

  before do
    hold_first_era!(url: boot_url, domain: "Ledger", source: shape_v1)
    registry_for(shape_v1)
  end

  context "with a shape no era holds, booted without a mint request" do
    let(:unminted) { registry_for(shape_v3, translation_source: edge_v1_to_v3) }

    it "reads the latest held era" do
      expect { adapter_for(unminted, era: 1, unminted: true).entries }.not_to raise_error
    end

    it "refuses a write, naming the mint entry point", :aggregate_failures do
      expect(write_error(adapter_for(unminted, era: 1, unminted: true)))
        .to include("the shape is not minted yet; run the mint entry point")
    end

    it "does not name a superseding era for it" do
      expect(unminted.superseded_eras["Ledger"]).to be_nil
    end
  end

  context "with a checkout whose era a mint has superseded" do
    before do
      registry_for(shape_v2, translation_source: edge_v1_to_v2, settings: mint_request_settings)
    end

    let(:old) { registry_for(shape_v1) }

    it "refuses a write, naming the era that superseded it", :aggregate_failures do
      expect(write_error(adapter_for(old, era: 1, superseded_by: 2)))
        .to include("which era 2 has superseded")
    end

    it "does not describe it as unminted" do
      expect(write_error(adapter_for(old, era: 1, superseded_by: 2))).not_to include("not minted")
    end
  end

  context "with a mint boot carrying its request" do
    let(:minted) do
      registry_for(shape_v2, translation_source: edge_v1_to_v2, settings: mint_request_settings)
    end

    it "lets the mint boot write to the era it minted" do
      expect(write_error(adapter_for(minted, era: 2))).to be_nil
    end
  end
end
