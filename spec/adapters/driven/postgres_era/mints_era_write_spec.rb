require "hecks"
require "hecks/ports/persistence/plugins/era"
require_relative "../../../support/postgres_probe"
require_relative "../../../support/scratch_postgres"
require_relative "../../../support/fenced_owner"
require_relative "../../../support/era_registry_loading"
require_relative "../../../support/mint_request_support"
require_relative "../../../support/first_era_hold"

# The one write an unminted boot lets through: the record of a command that declares `mints_era
# true`. Every other write from that boot is refused by name, and a superseded boot refuses the
# mint command's record as well.
RSpec.describe "a mints_era command's record through an unminted boot", :io do
  include EraRegistryLoading
  include MintRequestSupport
  include FirstEraHold

  MINTS_ERA_DB = "hecks_mints_era_spec".freeze

  scratch_postgres MINTS_ERA_DB, fenced: true

  def boot_url = FencedOwner.url(MINTS_ERA_DB)

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

  # Boots the era check of `source` against the database, with `settings` added to a copy that
  # owns it.
  def registry_for(source, translation_source: nil, settings: {})
    registry = load_registry(source, translation_source: translation_source)
    Hecks::Adapters::PostgresEra::LineageManager.check!(
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
    Hecks::Adapters::PostgresEra.new(aggregate: registry.bluebooks.values.first.aggregate("Acct"),
                                     settings:  settings)
  end

  # A journal entry for the `Acct` record; `mints_era` marks it as a mint command's own record.
  def entry(mints_era: false)
    Hecks::Ports::Persistence::Entry.new(operation: "save", id: "acct-1",
                                         state: { amount: { "cents" => 5 }, kind: { "label" => "biz" } },
                                         mirrors: nil, mints_era: mints_era)
  end

  # The refusal message of writing `record` through `adapter`, or nil when the write went through.
  def write_error(adapter, record = entry)
    adapter.append(record)
    nil
  rescue Hecks::Runtime::WiringError => e
    e.message
  end

  let(:unminted) { registry_for(shape_v3) }

  before do
    hold_first_era!(url: boot_url, domain: "Ledger", source: shape_v1)
    registry_for(shape_v1)
  end

  it "refuses a plain write from an unminted boot" do
    expect(write_error(adapter_for(unminted, era: 1, unminted: true)))
      .to include("the shape is not minted yet")
  end

  it "writes a mints_era command's own record through an unminted boot" do
    expect(write_error(adapter_for(unminted, era: 1, unminted: true), entry(mints_era: true))).to be_nil
  end

  it "refuses another write from the same unminted boot after that record went through", :aggregate_failures do
    adapter = adapter_for(unminted, era: 1, unminted: true)
    adapter.append(entry(mints_era: true))
    expect { adapter.append(entry) }.to raise_error(Hecks::Runtime::WiringError, /not minted yet/)
  end

  context "with a checkout whose era a mint has superseded" do
    before do
      registry_for(shape_v2, translation_source: edge_v1_to_v2, settings: mint_request_settings)
    end

    let(:old) { registry_for(shape_v1) }

    it "refuses a mints_era command's record, naming the era that superseded it" do
      expect(write_error(adapter_for(old, era: 1, superseded_by: 2), entry(mints_era: true)))
        .to include("which era 2 has superseded")
    end

    it "refuses a mints_era command's plain save from the superseded boot, naming the era" do
      expect(plain_save_error(adapter_for(old, era: 1, superseded_by: 2), mints_era: true))
        .to include("which era 2 has superseded")
    end
  end

  # The same record written through `AppendOnly#save`, the plain path a command takes when its
  # strategy is not atomic put; `mints_era:` is what the interpreter passes for its command.
  def plain_save_error(adapter, mints_era:)
    Hecks::Ports::Persistence::AppendOnly.new(adapter).save(acct_record, mints_era: mints_era)
    nil
  rescue Hecks::Runtime::WiringError => e
    e.message
  end

  def acct_record
    Struct.new(:id, :state).new("acct-1", { amount: { "cents" => 5 }, kind: { "label" => "biz" } })
  end

  it "writes a mints_era command's own record through an unminted boot on the plain save path" do
    expect(plain_save_error(adapter_for(unminted, era: 1, unminted: true), mints_era: true)).to be_nil
  end

  it "refuses another command's plain save from the same unminted boot after the mint record went through" do
    adapter = adapter_for(unminted, era: 1, unminted: true)
    plain_save_error(adapter, mints_era: true)
    expect(plain_save_error(adapter, mints_era: false)).to include("the shape is not minted yet")
  end
end
